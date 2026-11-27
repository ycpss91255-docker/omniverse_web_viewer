#!/usr/bin/env bats
#
# validated_key_reach_spec.bats -- a key the schema accepts has to reach
# the artifact it is a setting for.
#
# base#1094 measured five keys that `_schema_validate` accepted and
# nothing downstream consumed, so the operator's setting silently did
# nothing. Two of the five were "never emitted anywhere" (`[network] pid`
# outside `host`, and the whole of `[logging]` in the field-deploy
# bundle); two were "emitted, then overruled by another key with no
# diagnostic" (`[resources] shm_size` under the shipped `ipc = host`, and
# `[network] mode` beside a `network_name`); one was "the validator
# cannot express the value at all" (`[deploy] dri_groups`).
#
# why: Covers base#1094 -- the keys that validate and then never reach
# the emitted artifact. The DERIVED gate here is the one that matters:
# `_resolve_deploy_context` is the code's own declaration of which
# config values the field bundle is built from, so its populated record
# IS the population, and every field of it has to be able to change the
# generated bundle under SOME configuration. A per-key assertion naming
# today's five would stay green while the sixth grew. The explicit tests
# in validated_key_explicit_spec.bats cover the three defects a
# reachability check cannot see: a value that reaches one tier and not
# the other, and a value another key silently overrules.
#
# The two tiers are the dev compose (`generate_compose_yaml`) and the
# field-deploy bundle (`_generate_resolved_compose`). They are separate
# emitters over the same config, which is why base#1094's `[logging]`
# gap existed at all -- one of them called `_emit_logging_block` and the
# other had never heard of it.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/validated_key_reach_helper"

# The fields whose value legitimately reaches no line of the bundle's
# compose.yaml, each with the reason. An entry here is a claim about
# WHERE the value goes, not permission for it to go nowhere.
declare -gA _REACH_EXEMPT=(
  [build_network]="build-time only: the bundle ships a pre-built image and carries no build: section, so a build network has nothing to configure there"
  [env_str]="rides the bundle .env, deliberately NOT compose environment: -- compose ranks environment: above env_file, so a value left there would make the operator's .env.local override silently inert (_generate_resolved_compose's header states this)"
  [watchdog_env_str]="same as env_str: the WATCHDOG_* thresholds are the operator's field-retunable knobs, so they ride .env where .env.local can override them"
)

# Print the stdin lines whose 0-based index i has i % <K> == <k>
# (base#2003): one part of the reach gate's field list.
_reach_part_of() {
  awk -v k="${1:?missing part}" -v n="${2:?missing part count}" \
    '(NR - 1) % n == k'
}

# The reach gate's title, without its part suffix (base#2003). The 4 part
# @tests below spell it out literally, because the catalogue, count and
# issueref tools read `@test` lines as text.
_REACH_TITLE='every deploy-context field can change the generated bundle compose, or is a declared exemption'

# Print n-1 when <title> is exactly "<_REACH_TITLE>, part n of 4
# (base#1094)" for n in 1..4; otherwise say so and fail (base#2003).
_reach_part_from_title() {
  local _title="${1?missing title}" _n
  for _n in 1 2 3 4; do
    if [[ "${_title}" == "${_REACH_TITLE}, part ${_n} of 4 (base#1094)" ]]; then
      echo "$(( _n - 1 ))"
      return 0
    fi
  done
  echo "not a reach-part title: ${_title}"
  return 1
}

# Print, one per line, the non-exempt fields of the context record named
# <ctx> that the reach part named by this @test's title checks
# (base#2003). Fails, saying why, when the title is not a reach-part
# title, when a stage of the selection fails, or when it selects nothing.
_reach_part_fields() {
  local -n _rpf_ctx="${1:?missing context record}"
  local _k _all _part _f
  _k="$(_reach_part_from_title "${BATS_TEST_DESCRIPTION}")" || { echo "${_k}"; return 1; }
  _all="$(set -o pipefail
    for _f in "${!_rpf_ctx[@]}"; do
      [[ -v "_REACH_EXEMPT[${_f}]" ]] || printf '%s\n' "${_f}"
    done | LC_ALL=C sort)" || { echo "listing the deploy-context fields failed"; return 1; }
  _part="$(_reach_part_of "${_k}" 4 <<< "${_all}")" || { echo "selecting reach part ${_k} failed"; return 1; }
  [[ -n "${_part}" ]] || { echo "reach part ${_k} selected no field"; return 1; }
  printf '%s\n' "${_part}"
}

# The reach check for the part this @test's title names (base#2003): each
# non-exempt field of that part must change the bundle compose.
_reach_check_part() {
  local _base_dir _baseline="${TEMP_DIR}/baseline.yaml"
  _base_dir="$(_conf_dir "${_REACH_BASE}")"
  local -A _ctx=() _base_binds=()
  _resolve_deploy_context "${_base_dir}" _ctx

  local _sel
  _sel="$(_reach_part_fields _ctx)" || { echo "${_sel}"; return 1; }
  local -a _fields=()
  mapfile -t _fields <<< "${_sel}"

  _generate_resolved_compose "${_base_dir}" runtime img name "${_baseline}" _base_binds _ctx

  local _f _inert="" _probe _dir _out
  for _f in "${_fields[@]}"; do
    _probe="${_REACH_PROBE[${_f}]:-}"
    [[ -n "${_probe}" ]] || continue   # the probe-completeness test owns this
    _dir="$(_conf_dir "${_probe}")"
    # A probe the bridge refuses would read as "the key changed nothing".
    run toml_bridge_parse "${_dir}/setup.toml"
    assert_success
    _out="${TEMP_DIR}/probe-${_f}.yaml"
    _reach_bundle "${_dir}" "${_out}"
    cmp -s "${_baseline}" "${_out}" && _inert+=" ${_f}"
  done
  [ -z "${_inert}" ] || {
    echo "deploy-context fields that cannot change the bundle compose:${_inert}"
    echo "each is a value the schema accepts and the emitter drops; emit it, or add a _REACH_EXEMPT row saying where it does go"
    false
  }
}

# ════════════════════════════════════════════════════════════════════
# The derived gate
# ════════════════════════════════════════════════════════════════════

# why: base#1094 -- `_resolve_deploy_context`'s populated record is the
# code's own declaration of which config values the field bundle is
# built from, so holding the probe table equal to it is what stops this
# gate from quietly covering 23 of 24 fields. Measured on 0faacb57: 24
# fields.
@test "every deploy-context field has a reach probe, and every probe names a field (base#1094)" {
  local -A _ctx=()
  _resolve_deploy_context "$(_conf_dir "${_REACH_BASE}")" _ctx
  (( ${#_ctx[@]} > 0 )) || { echo "the deploy context resolved to nothing"; false; }

  local _f _missing="" _orphan=""
  for _f in "${!_ctx[@]}"; do
    [[ -v "_REACH_PROBE[${_f}]" ]] || _missing+=" ${_f}"
  done
  for _f in "${!_REACH_PROBE[@]}"; do
    [[ -v "_ctx[${_f}]" ]] || _orphan+=" ${_f}"
  done
  [ -z "${_missing}" ] || {
    echo "deploy-context fields with no reach probe:${_missing}"
    false
  }
  [ -z "${_orphan}" ] || {
    echo "probes naming no deploy-context field:${_orphan}"
    false
  }
}

# why: base#1094 -- the defect's exact shape: a key validates, the
# resolver reads it into the context, and the emitter never consumes it,
# so the operator's setting does nothing and nothing says so. `pid_mode`
# and the two `[logging]` fields were in that state. The population is
# derived from the context record, so a field added tomorrow and then
# dropped by the emitter fails here; the alternative -- naming today's
# fields -- is the assertion that would have passed all through
# base#1094.
# Split into 4 parts (base#2003) so no one @test runs past the per-test
# timeout under coverage. Each part checks the fields `_reach_part_of`
# assigns it; a field with no probe is the probe-completeness test's job.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 1 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#1094 -- part 2 of the reach gate split by base#2003. Part 1
# carries the rationale.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 2 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#1094 -- part 3 of the reach gate split by base#2003. Part 1
# carries the rationale.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 3 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#1094 -- part 4 of the reach gate split by base#2003. Part 1
# carries the rationale.
@test "every deploy-context field can change the generated bundle compose, or is a declared exemption, part 4 of 4 (base#1094)" {
  _reach_check_part
}

# why: base#2003 -- the reach gate runs in parts so no one @test runs
# past the per-test timeout under coverage, and a part is the fields at
# index i with i % K == k. Over a worked literal, so a constant part, a
# dropped index, or an index counted from 1 each gives other lines.
@test "a reach part is every K-th field from its index (base#2003)" {
  local _in
  _in="$(printf '%s\n' a b c d e f)"
  run _reach_part_of 0 4 <<< "${_in}"
  assert_success
  assert_output "$(printf '%s\n' a e)"
  run _reach_part_of 1 4 <<< "${_in}"
  assert_success
  assert_output "$(printf '%s\n' b f)"
  run _reach_part_of 2 4 <<< "${_in}"
  assert_success
  assert_output "c"
  run _reach_part_of 3 4 <<< "${_in}"
  assert_success
  assert_output "d"
}

# why: base#2003 -- each reach part takes its part from its own title,
# and only a title equal to one of the 4 exact reach-part titles gives
# one. The titles are typed here rather than read from the constant, so
# a drift between the two fails. A copy-edited title, a trailing word, a
# part outside 1..4 and a title with no part are each refused.
@test "a reach part number comes only from an exact reach-part title (base#2003)" {
  local _t='every deploy-context field can change the generated bundle compose, or is a declared exemption'
  run _reach_part_from_title "${_t}, part 1 of 4 (base#1094)"
  assert_success
  assert_output "0"
  run _reach_part_from_title "${_t}, part 4 of 4 (base#1094)"
  assert_success
  assert_output "3"

  local _bad
  for _bad in \
    "copy-edited reach title, part 2 of 4 (base#1094)" \
    "${_t}, part 2 of 4 (base#1094) x" \
    "${_t}, part 5 of 4 (base#1094)" \
    "${_t} (base#1094)"; do
    run _reach_part_from_title "${_bad}"
    assert_failure
    refute_output --regexp '^[0-9]+$'
  done
}

# why: base#2003 -- a part @test only runs if it is registered. Bats
# refuses two tests with one title in a file, and every part takes its
# part from an exact title, so 4 registered exact titles are parts 1..4
# once each. Counted through bats' own --count and --filter, so a
# deleted part makes the count 3.
@test "the four reach parts are registered once each (base#2003)" {
  run bats --count --filter "^${_REACH_TITLE}, part [1-4] of 4 \\(base#1094\\)\$" "${BATS_TEST_FILENAME}"
  assert_success
  assert_output "4"
}

# why: base#2003 -- the 4 parts together have to check every non-exempt
# field exactly once. Each part's fields come from `_reach_part_fields`
# under that part's own title, the same call the part @tests make, so a
# selection that hands every part the same index repeats one part and
# drops the other three, and the sorted union differs from the field list.
@test "the four reach parts together select every non-exempt field once (base#2003)" {
  local -A _ctx=()
  _resolve_deploy_context "$(_conf_dir "${_REACH_BASE}")" _ctx
  local _t='every deploy-context field can change the generated bundle compose, or is a declared exemption'
  local _n _sel _got="" _f _want
  for _n in 1 2 3 4; do
    _sel="$(BATS_TEST_DESCRIPTION="${_t}, part ${_n} of 4 (base#1094)" _reach_part_fields _ctx)" \
      || { echo "part ${_n}: ${_sel}"; false; }
    _got+="${_sel}"$'\n'
  done
  _want="$(for _f in "${!_ctx[@]}"; do
    [[ -v "_REACH_EXEMPT[${_f}]" ]] || printf '%s\n' "${_f}"
  done | LC_ALL=C sort)"
  [ -n "${_want}" ] || { echo "the deploy context has no non-exempt field"; false; }
  assert_equal "$(printf '%s' "${_got}" | LC_ALL=C sort)" "${_want}"
}

# why: base#2003 -- a part whose field selection fails, or selects
# nothing, has checked nothing, so it has to fail rather than report a
# pass over zero fields. The selection's last stage is replaced here by
# one that prints a valid field and then fails -- so only its exit status
# can fail the part -- and by one that prints nothing.
@test "a reach part fails when its field selection fails or selects nothing (base#2003)" {
  local _t='every deploy-context field can change the generated bundle compose, or is a declared exemption, part 1 of 4 (base#1094)'
  _reach_part_of() { head -n 1; return 1; }
  BATS_TEST_DESCRIPTION="${_t}" run _reach_check_part
  assert_failure
  assert_output --partial 'selecting reach part 0 failed'
  _reach_part_of() { :; }
  BATS_TEST_DESCRIPTION="${_t}" run _reach_check_part
  assert_failure
  assert_output --partial 'reach part 0 selected no field'
}

# why: base#1094 -- an exemption is a claim about where the value goes,
# and an unexplained one is the hole this gate exists to close. Mirrors
# schema.sh's SCHEMA_FREEFORM reason rule.
@test "every reach exemption names a deploy-context field and carries a reason (base#1094)" {
  local -A _ctx=()
  _resolve_deploy_context "$(_conf_dir "${_REACH_BASE}")" _ctx
  local _k _bad=""
  for _k in "${!_REACH_EXEMPT[@]}"; do
    [[ -v "_ctx[${_k}]" ]] || _bad+=" ${_k}(no such field)"
    [[ -n "${_REACH_EXEMPT[${_k}]}" ]] || _bad+=" ${_k}(no reason)"
  done
  [ -z "${_bad}" ] || { echo "bad exemptions:${_bad}"; false; }
}
