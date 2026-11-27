#!/usr/bin/env bats
#
# multi_distro_build_worker_yaml_spec.bats — structural assertions for
# `.github/workflows/multi-distro-build-worker.yaml` (B-1 dispatcher
# extended to N-D matrix-mode via).
#
# The dispatcher is a two-job reusable workflow on top of
# build-worker.yaml:
#
# 1. `resolve-matrix` — shell and jq selector that emits a `matrix`
#    `include`-shape JSON array output based on `github.event_name`.
#    `pull_request` -> `pr_matrix` (subset); everything else (tag push,
#    main push, workflow_dispatch) -> `tag_matrix` (full release matrix).
#
# 2. `call-build` — strategy.matrix job invoking `build-worker.yaml` by
#    its full path at this release's tag, per matrix cell. Each cell
#    MUST have `name` (used for image_name suffix + cache scope) and
#    `build_args` (forwarded verbatim to build-worker.yaml). Derives
#    per-shard `image_name` as `<image_name>-<matrix.name>` so GHCR tags
#    disambiguate across cells. Per-cell
#    `cache_variant: ${{ matrix.name }}` so buildx GHA cache shards by
#    cell name (matches's per-variant scope pattern).
#
# 3. `ci-passed` — rollup aggregating the matrix result for branch
#    protection. Matches the existing rollup naming used by
#    env/ros_distro / env/ros2_distro per CLAUDE.md's status-check
#    table, so downstream branch-protection contexts don't change when
#    adopting this dispatcher.
#
# BREAKING since v0.32.0: the 1D inputs `pr_distros` /
# `tag_distros` / `distro_input_name` / `extra_build_args` are removed;
# callers must use `pr_matrix` / `tag_matrix` (full JSON include-shape)
# instead.
#
# why: Structural assertions for
# `.github/workflows/multi-distro-build-worker.yaml` (#325 B-1 dispatcher,
# extended to N-D matrix-mode via #344 in v0.32.0). The dispatcher fans a
# per-event `include`-shape matrix across `build-worker.yaml` matrix shards
# so multi-distro / multi-variant caller `main.yaml`s (`env/ros_distro`,
# `env/ros2_distro`, `app/ros1_bridge`) stop copy-pasting a `${{
# github.event_name == 'pull_request' && ... || ... }}` expression. Three
# jobs:
#
# 1. **`resolve-matrix`** — shell and jq selector emitting a `matrix`
# JSON-array output (`include`-shape, each entry has `name` + `build_args`
# plus arbitrary additional fields). `pull_request` -> `pr_matrix` (subset);
# anything else (tag push, main push, `workflow_dispatch`) -> `tag_matrix`
# (release validation matrix).
#
# 2. **`call-build`** — strategy.matrix job invoking
# `build-worker.yaml` per matrix cell. Derives per-shard `image_name` as
# `<image_name>-<matrix.name>`, forwards `matrix.build_args` verbatim as
# `build_args`, and shards buildx GHA cache by name via `cache_variant: ${{
# matrix.name }}` (reuses #272's per-variant scope contract). `fail-fast:
# false` so one shard's failure doesn't cancel siblings.
#
# 3. **`ci-passed`** — rollup gate for branch protection. Matches the
# existing `ci-passed` rollup naming used by env/ros_distro /
# env/ros2_distro per CLAUDE.md's status-check table, so downstream
# branch-protection contexts don't change on adoption.
#
# **BREAKING since v0.32.0 (#344)**: legacy 1D inputs `pr_distros` /
# `tag_distros` / `distro_input_name` / `extra_build_args` were removed; the
# 14 v0.29-era tests covering those inputs are replaced by 16 tests covering
# the new matrix-mode shape (incl. a negative assertion that the 1D inputs
# are gone).
#
# Grouped by concern:
#
# - Declares `workflow_call`
#
# - Required inputs: `pr_matrix`, `tag_matrix`, `image_name`
#
# - Legacy 1D inputs gone (no `pr_distros` / `tag_distros` /
# `distro_input_name` / `extra_build_args`)
#
# - `pr_matrix` description documents required `name` + `build_args` fields
#
# - `tag_matrix` description documents required `name` + `build_args` fields
#
# - Passthrough inputs mirror build-worker (build_runtime / platforms /
# context_path / dockerfile_path / build_contexts). The tooling image is
# NOT among them: build-worker derives it from its own version-matched
# checkout, so there is nothing for a dispatcher to forward (closes #1122)
#
# - `resolve-matrix` emits `matrix` output (include-shape)
#
# - `resolve-matrix` branches on `github.event_name == 'pull_request'`
#
# - `call-build` calls `build-worker.yaml` by its full path at the release in
# `.version`; no reusable workflow calls its next level by a `./` path
#
# - `call-build` matrix `include:
# fromJSON(needs.resolve-matrix.outputs.matrix)`
#
# - `call-build` per-shard `image_name: <image_name>-<matrix.name>` (hyphen)
#
# - `call-build` forwards `build_args: ${{ matrix.build_args }}` verbatim
#
# - `call-build` `cache_variant: ${{ matrix.name }}` (per-cell cache scope)
#
# - `call-build` `fail-fast: false`
#
# - `ci-passed` rollup depends on `call-build`, runs with `if: always()`
#
# - `ci-passed` declares `name: ci-passed` to satisfy branch protection
# contract
#
# - Every job's grant pinned as an exact per-job entry set, over the job
# list derived from the file (all three jobs `contents: read` -- the
# dispatcher builds nothing and pushes nothing)

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/multi-distro-build-worker.yaml"
  assert_spec_subject "${WF}" \
      "the multi-distro build worker this spec pins"
  # Scratch for the cases that RUN the resolve-matrix step's own body.
  SCRATCH="$(mktemp -d)"
}

teardown() {
  if [[ -n "${SCRATCH:-}" ]]; then
    rm -rf "${SCRATCH}"
  fi
}

# _on_block -- the code lines of the trigger + workflow_call interface, from
# `on:` to `jobs:`. Comment-stripped, so the paragraphs that discuss the
# removed 1D inputs by name cannot satisfy the assertion that they are gone.
_on_block() {
  awk '/^on:/{flag=1} /^jobs:/{flag=0} flag' "${WF}" | strip_comments
}

# _input_block <input> -- the code lines of one workflow_call input's mapping.
_input_block() {
  awk -v _key="^      ${1}:" \
      '$0 ~ _key {flag=1; next} /^      [a-z]/{flag=0} flag' "${WF}" \
    | strip_comments
}

# _runner_output <file> <name> -- what the runner reads for output <name> from
# a GITHUB_OUTPUT file: `name=value` lines and `name<<DELIMITER` blocks, and a
# failure on any other line, in the runner's own words. Grepping the file for
# `name=` would accept a file the runner refuses (base#2160).
_runner_output() {
  awk -v want="${2}" '
    function keep() { if (name == want) { result = value; got = 1 } }
    delim != "" && $0 == delim { keep(); delim = ""; next }
    delim != "" { value = value sep $0; sep = "\n"; next }
    $0 == "" { next }
    {
      eq = index($0, "=")
      here = index($0, "<<")
      if (eq && (!here || eq < here)) {
        name = substr($0, 1, eq - 1)
        value = substr($0, eq + 1)
        keep()
        next
      }
      if (here) {
        name = substr($0, 1, here - 1)
        delim = substr($0, here + 2)
        value = sep = ""
        next
      }
      printf "Invalid format \047%s\047\n", $0
      bad = 1
      exit
    }
    END {
      if (bad) { exit 1 }
      if (delim != "") { print "unterminated block"; exit 1 }
      if (!got) { print "no such output"; exit 1 }
      print result
    }
  ' "${1}"
}

# _resolved_matrix <event> <pr_matrix> <tag_matrix> -- RUN the resolve-matrix
# step for one call of the worker and print the `matrix` output the runner
# hands to call-build. 1 when the step fails, 3 when it succeeds and the runner
# has no matrix to hand over: the job is green then, and only one of the two
# is a refusal.
_resolved_matrix() {
  local _body _status=0
  _body="$(yaml_step_run "${WF}" resolve-matrix r)" || _status=$?
  if [[ "${_status}" -ne 0 || -z "${_body}" || "${_body}" == 'null' ]]; then
    printf 'BUG: could not read the resolve-matrix step of %s\n' "${WF}"
    return 2
  fi
  printf '%s\n' "${_body}" > "${SCRATCH}/step.sh"
  : > "${SCRATCH}/output"
  EVENT_NAME="${1}" PR_MATRIX="${2}" TAG_MATRIX="${3}" \
    GITHUB_OUTPUT="${SCRATCH}/output" bash "${SCRATCH}/step.sh" || return 1
  _runner_output "${SCRATCH}/output" matrix || return 3
}

# _assert_resolves <event> <pr_matrix> <tag_matrix> <expected> -- the step
# succeeds and call-build's fromJSON reads the JSON value <expected> spells.
_assert_resolves() {
  local _expected
  _expected="$(jq -cS . <<< "${4}")" || fail "the expected value is not JSON"
  run _resolved_matrix "${1}" "${2}" "${3}"
  assert_success
  run jq -cS . <<< "${output}"
  assert_success
  assert_output "${_expected}"
}

# _assert_refuses <event> <pr_matrix> <tag_matrix> <input> -- the step fails
# naming <input>, and leaves no matrix output behind.
_assert_refuses() {
  run _resolved_matrix "${1}" "${2}" "${3}"
  assert_failure 1
  assert_output --partial '::error::'
  assert_output --partial "${4}"
  run cat "${SCRATCH}/output"
  assert_output ''
}

# What a caller writes under `tag_matrix: |`, as app/ros1_bridge does.
readonly _MULTI='[
  {"name": "humble", "build_args": "ROS2_DISTRO=humble"},
  {"name": "jazzy",  "build_args": "ROS2_DISTRO=jazzy"}
]
'
readonly _SINGLE='[{"name":"humble","build_args":"ROS2_DISTRO=humble"}]'

# ── workflow_call interface ─────────────────────────────────────────

@test "multi-distro-build-worker.yaml: declares workflow_call (#325 B-1)" {
  run code_grep -E '^\s+workflow_call:' "${WF}"
  assert_success
}

@test "multi-distro-build-worker.yaml: required inputs include pr_matrix + tag_matrix + image_name (#344 matrix-mode)" {
  run _on_block
  assert_success
  assert_output --partial 'pr_matrix:'
  assert_output --partial 'tag_matrix:'
  assert_output --partial 'image_name:'
}

@test "multi-distro-build-worker.yaml: legacy 1D inputs are gone (no pr_distros / tag_distros / distro_input_name / extra_build_args) (#344 BREAKING)" {
  run _on_block
  assert_success
  refute_output --partial 'pr_distros:'
  refute_output --partial 'tag_distros:'
  refute_output --partial 'distro_input_name:'
  refute_output --partial 'extra_build_args:'
}

@test "multi-distro-build-worker.yaml: pr_matrix description mentions required name + build_args fields per entry (#344)" {
  run _input_block pr_matrix
  assert_success
  assert_output --partial 'name'
  assert_output --partial 'build_args'
}

@test "multi-distro-build-worker.yaml: tag_matrix description mentions required name + build_args fields per entry (#344)" {
  run _input_block tag_matrix
  assert_success
  assert_output --partial 'name'
  assert_output --partial 'build_args'
}

@test "multi-distro-build-worker.yaml: passthrough inputs mirror build-worker (build_runtime / platforms / context_path / dockerfile_path / build_contexts) (closes #1122)" {
  run _on_block
  assert_success
  assert_output --partial 'build_runtime:'
  # test_tools_version is deliberately absent: build-worker derives the
  # tooling image from its own version-matched checkout, so a dispatcher
  # forwarding a version would be reintroducing the second source.
  refute_output --partial 'test_tools_version:'
  assert_output --partial 'platforms:'
  assert_output --partial 'context_path:'
  assert_output --partial 'dockerfile_path:'
  assert_output --partial 'build_contexts:'
}

# ── resolve-matrix job ───────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: resolve-matrix job emits matrix output (#344 include-shape)" {
  run yaml_job_lines "${WF}" resolve-matrix
  assert_success
  assert_output --partial 'matrix: ${{ steps.r.outputs.matrix }}'
}

@test "multi-distro-build-worker.yaml: resolve-matrix branches on github.event_name == pull_request (#344)" {
  run yaml_job_lines "${WF}" resolve-matrix
  assert_success
  assert_output --partial 'EVENT_NAME: ${{ github.event_name }}'
  assert_output --partial '"${EVENT_NAME}" == "pull_request"'
  assert_output --partial 'PR_MATRIX: ${{ inputs.pr_matrix }}'
  assert_output --partial 'TAG_MATRIX: ${{ inputs.tag_matrix }}'
}

# why: base#2160. app/ros1_bridge writes tag_matrix as a block scalar, and the
# runner refused the multi-line `matrix=` line with "Invalid format ']'", so
# every push to main and every release failed while pull requests passed.
@test "multi-distro-build-worker.yaml: a multi-line tag_matrix reaches fromJSON on push and workflow_dispatch (base#2160)" {
  _assert_resolves push "${_SINGLE}" "${_MULTI}" "${_MULTI}"
  _assert_resolves workflow_dispatch "${_SINGLE}" "${_MULTI}" "${_MULTI}"
}

# why: base#2160. The same write on the other branch of the event check.
@test "multi-distro-build-worker.yaml: a multi-line pr_matrix reaches fromJSON on pull_request (base#2160)" {
  _assert_resolves pull_request "${_MULTI}" "${_SINGLE}" "${_MULTI}"
}

# why: base#2160. The single-line spelling worked before and must keep its
# value, and each event must still pick its own input.
@test "multi-distro-build-worker.yaml: a single-line matrix reaches fromJSON, from the input the event selects (base#2160)" {
  local _other='[{"name":"jazzy","build_args":"ROS2_DISTRO=jazzy"}]'
  _assert_resolves pull_request "${_SINGLE}" "${_other}" "${_SINGLE}"
  _assert_resolves push "${_SINGLE}" "${_other}" "${_other}"
}

# why: base#2160. A fix that joins or rewrites the lines as text can damage a
# value: an escaped newline in build_args, spaces, and the characters the
# GITHUB_OUTPUT format itself uses.
@test "multi-distro-build-worker.yaml: an entry's own characters survive the hand-over (base#2160)" {
  local _value='[
  {"name": "a", "build_args": "A=1\nB=two  words\tC<<EOF", "note": "\"q\" \\ $(x) é %0A"}
]'
  _assert_resolves push "${_SINGLE}" "${_value}" "${_value}"
}

# why: base#2160. An unreadable matrix must fail in this job, naming the input
# the caller wrote, and not as an empty matrix in call-build. A second JSON
# document and a non-array are refused for the same reason: `include:` takes
# one array.
@test "multi-distro-build-worker.yaml: an input that is not one JSON array is refused by name (base#2160)" {
  local _bad
  for _bad in '[{"name":"humble",}' 'humble' '' $'\n' '{"name":"humble"}' '[] []' 'null'; do
    _assert_refuses push "${_SINGLE}" "${_bad}" tag_matrix
    _assert_refuses pull_request "${_bad}" "${_SINGLE}" pr_matrix
  done
}

# why: base#2160. The event selects one input; what the other holds must not
# fail a run that never uses it.
@test "multi-distro-build-worker.yaml: the input the event does not select is not judged (base#2160)" {
  _assert_resolves push 'not json' "${_MULTI}" "${_MULTI}"
  _assert_resolves pull_request "${_MULTI}" '' "${_MULTI}"
}

# ── call-build matrix job ────────────────────────────────────────────

# why: base#2171. A caller that names the dispatcher by an annotated tag hands
# a `./` call the tag object's sha as the next level's ref, and push and
# workflow_dispatch runs then fail at startup. A full path with a ref is
# resolved as written. `uses:` takes no expression, so the ref is a literal;
# a release bump that moves `.version` without it fails here.
@test "multi-distro-build-worker.yaml: call-build calls build-worker by its full path at the .version release (base#2171)" {
  local _version _line
  local -a _uses=()
  _version="$(< /source/.version)"
  # shellcheck disable=SC1091
  source /source/dist/script/base/upstream.sh
  run yaml_job_lines "${WF}" call-build
  assert_success
  for _line in "${lines[@]}"; do
    if [[ "${_line}" =~ ^[[:space:]]*uses:[[:space:]]*(.*)$ ]]; then
      _uses+=("${BASH_REMATCH[1]}")
    fi
  done
  [ "${#_uses[@]}" -eq 1 ] || fail "call-build has ${#_uses[@]} uses: lines, expected 1"
  [ "${_uses[0]}" = "${BASE_UPSTREAM_SLUG}/.github/workflows/build-worker.yaml@${_version}" ] \
    || fail "call-build uses: ${_uses[0]}"
}

# why: base#2171. The startup failure belongs to the `./` form, not to this
# dispatcher, so every workflow a downstream repo can call is held to the rule.
# `$/` is the other same-repository form and carries no ref either.
@test "no reusable workflow calls its next level by a same-repository path (base#2171)" {
  local _file _found _hits="" _reusable=0
  for _file in /source/.github/workflows/*.yaml /source/.github/workflows/*.yml; do
    [[ -f "${_file}" ]] || continue
    grep -qE '^[[:space:]]+workflow_call:' "${_file}" || continue
    _reusable=$(( _reusable + 1 ))
    _found="$(strip_comments < "${_file}" \
      | grep -E "^[[:space:]]*uses:[[:space:]]*[\"']?[.\$]/\.github/workflows/" || true)"
    [[ -z "${_found}" ]] || _hits+="${_file##*/}: ${_found}"$'\n'
  done
  (( _reusable > 0 )) || fail "no workflow declares workflow_call, so nothing was checked"
  [ -z "${_hits}" ] || fail "reusable workflow with a same-repository uses: ${_hits}"
}

# why: base#2171. A full-path call names its release as a literal, so one left
# at another release runs that release's worker under this one's dispatcher.
@test "base workflows name a base workflow only at the .version release (base#2171)" {
  local _version _file _found _hits=""
  _version="$(< /source/.version)"
  # shellcheck disable=SC1091
  source /source/dist/script/base/upstream.sh
  for _file in /source/.github/workflows/*.yaml /source/.github/workflows/*.yml; do
    [[ -f "${_file}" ]] || continue
    _found="$(strip_comments < "${_file}" \
      | grep -E "^[[:space:]]*uses:[[:space:]]*[\"']?${BASE_UPSTREAM_SLUG}/" \
      | grep -vE "@${_version//./\\.}[\"']?([[:space:]]+#.*)?[[:space:]]*\$" || true)"
    [[ -z "${_found}" ]] || _hits+="${_file##*/}: ${_found}"$'\n'
  done
  [ -z "${_hits}" ] || fail "base workflow ref not at ${_version}: ${_hits}"
}

@test "multi-distro-build-worker.yaml: call-build matrix is include: fromJSON(needs.resolve-matrix.outputs.matrix) (#344 N-D)" {
  run yaml_job_lines "${WF}" call-build
  assert_success
  assert_output --partial 'include: ${{ fromJSON(needs.resolve-matrix.outputs.matrix) }}'
}

@test "multi-distro-build-worker.yaml: call-build derives per-shard image_name as <image_name>-<matrix.name> (hyphen, #344)" {
  # Hyphen separator chosen to match the existing org pattern (e.g.
  # app/ros1_bridge's pre-dispatcher main.yaml shipped
  # `ros1_bridge-${distro}`). v0.29.1 fix carried over.
  run yaml_job_lines "${WF}" call-build
  assert_success
  assert_output --partial 'image_name: ${{ inputs.image_name }}-${{ matrix.name }}'
  refute_output --partial 'image_name: ${{ inputs.image_name }}_${{ matrix.name }}'
}

@test "multi-distro-build-worker.yaml: call-build passes matrix.build_args verbatim as build_args (#344)" {
  run yaml_job_lines "${WF}" call-build
  assert_success
  assert_output --partial 'build_args: ${{ matrix.build_args }}'
}

@test "multi-distro-build-worker.yaml: call-build splits buildx cache by name via cache_variant: matrix.name (#272 reuse, #344)" {
  run yaml_job_lines "${WF}" call-build
  assert_success
  assert_output --partial 'cache_variant: ${{ matrix.name }}'
}

@test "multi-distro-build-worker.yaml: call-build has fail-fast: false so one shard's failure doesn't cancel siblings (#325 B-1)" {
  run yaml_job_lines "${WF}" call-build
  assert_success
  assert_output --partial 'fail-fast: false'
}

# ── ci-passed rollup ─────────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: ci-passed rollup job exists, depends on call-build, runs even if matrix failed (#325 B-1)" {
  run yaml_job_lines "${WF}" ci-passed
  assert_success
  assert_output --partial 'needs: call-build'
  assert_output --partial 'if: ${{ always() }}'
  assert_output --partial 'NEEDS_RESULT'
  assert_output --partial 'needs.call-build.result'
}

@test "multi-distro-build-worker.yaml: ci-passed job has explicit name: ci-passed (matches existing multi-distro rollup contract) (#325 B-1)" {
  run yaml_job_lines "${WF}" ci-passed
  assert_success
  assert_output --partial 'name: ci-passed'
}

# ── Per-job least privilege ──────────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: every job's grant is pinned as an exact set (#957)" {
  # The dispatcher itself builds nothing and pushes nothing: resolve-matrix
  # emits JSON, call-build delegates to build-worker.yaml, ci-passed rolls
  # the matrix result up for branch protection. None of the three needs
  # more than a checkout, so all three are pinned to `contents: read`.
  #
  # This file is the reason the least-privilege guard was widened past
  # build-worker: it had three jobs and no `permissions:` line anywhere, so
  # every job ran on the CALLING repo's whole token while the guard next
  # door was green.
  # The exact set is what keeps that from coming back one scope at a time.
  # The job list is DERIVED, so a fourth job is named here on the day it
  # lands.
  run yaml_permission_surface "${WF}"
  assert_success
  assert_output 'resolve-matrix: contents: read
call-build: contents: read
ci-passed: contents: read'
}
