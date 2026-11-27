#!/usr/bin/env bats
#
# config_gen_s43_stage_golden_spec.bats -- the s43 stage-list corpus against
# the `.stages` goldens (base#2093, S43a-1 of base#2054).
#
# why: Before any Go parser exists, the shell `_parse_dockerfile_stages`
# (dist/script/docker/lib/stage.sh) is the oracle for the stage list. Every
# dockerfile/config-gen/testdata/corpus/s43/s43_stage_<case>.Dockerfile has
# one golden testdata/golden/s43/s43_stage_<case>.stages holding that
# function's stdout (one stage per line, trailing newline; empty output is a
# 0-byte file). The Go side must later match these byte for byte. The spec
# regenerates the list from the shell and compares it with the golden, and a
# partition check keeps fixtures and goldens one-to-one.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
  TESTDATA="/source/dockerfile/config-gen/testdata"
  CORPUS="${TESTDATA}/corpus/s43"
  GOLDEN="${TESTDATA}/golden/s43"
}

# _check_case <case> -- regenerate the stage list of s43_stage_<case>.Dockerfile
# from the shell and compare it byte for byte with the .stages golden.
_check_case() {
  local _name="s43_stage_${1}"
  [[ -f "${CORPUS}/${_name}.Dockerfile" ]] || {
    echo "fixture missing: ${_name}.Dockerfile" >&2
    return 1
  }
  [[ -f "${GOLDEN}/${_name}.stages" ]] || {
    echo "golden missing: ${_name}.stages" >&2
    return 1
  }
  _parse_dockerfile_stages "${CORPUS}/${_name}.Dockerfile" > "${BATS_TEST_TMPDIR}/${_name}.out"
  cmp -- "${BATS_TEST_TMPDIR}/${_name}.out" "${GOLDEN}/${_name}.stages"
}

# ── one test per case ───────────────────────────────────────────────────────

# why: the legacy baseline fixture lists no stage for the shell, so its golden is empty.
@test "s43 stage golden: legacy_baseline lists no stage" {
  run _check_case legacy_baseline
  assert_success
}

# why: the new baseline fixture lists no stage for the shell either, so its golden is empty.
@test "s43 stage golden: new_baseline lists no stage" {
  run _check_case new_baseline
  assert_success
}

# why: a devel-test stage is listed by name.
@test "s43 stage golden: devel_test lists devel-test" {
  run _check_case devel_test
  assert_success
}

# why: two optional stages come out in file order, one per line.
@test "s43 stage golden: extract lists headless then gui" {
  run _check_case extract
  assert_success
}

# why: the list follows the order of the FROM lines, not alphabetical order.
@test "s43 stage golden: order keeps file order" {
  run _check_case order
  assert_success
}

# why: a stage declared twice is listed once.
@test "s43 stage golden: dedup lists a repeated stage once" {
  run _check_case dedup
  assert_success
}

# why: a FROM inside a comment declares no stage.
@test "s43 stage golden: lower_comment skips a commented FROM" {
  run _check_case lower_comment
  assert_success
}

# ── literal expectations, independent of the goldens ────────────────────────

# why: the issue's table gives the expected stage lists; pin two of them as
# literals so a wrong golden cannot pass by being regenerated the same way.
@test "s43 stage golden: order golden is gamma, alpha, beta" {
  run cat "${GOLDEN}/s43_stage_order.stages"
  assert_success
  assert_output $'gamma\nalpha\nbeta'
}

# why: an empty stage list is a 0-byte file, not a file holding a blank line.
@test "s43 stage golden: baseline goldens are 0-byte files" {
  [[ -f "${GOLDEN}/s43_stage_legacy_baseline.stages" ]]
  [[ ! -s "${GOLDEN}/s43_stage_legacy_baseline.stages" ]]
  [[ -f "${GOLDEN}/s43_stage_new_baseline.stages" ]]
  [[ ! -s "${GOLDEN}/s43_stage_new_baseline.stages" ]]
}

# why: a missing Dockerfile is not an error, so the Go side needs the same
# empty output and rc 0.
@test "s43 stage golden: a missing Dockerfile gives empty output and rc 0" {
  run _parse_dockerfile_stages "${BATS_TEST_TMPDIR}/no_such.Dockerfile"
  assert_success
  assert_output ""
}

# ── the partition check ─────────────────────────────────────────────────────

# why: a fixture with no golden, or a golden with no fixture, must fail the
# spec so the corpus cannot drift from its goldens.
@test "s43 stage golden: every fixture has exactly one golden and no extra" {
  local _f _stem _bad=0
  for _f in "${CORPUS}"/s43_stage_*.Dockerfile; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .Dockerfile)"
    if [[ ! -f "${GOLDEN}/${_stem}.stages" ]]; then
      echo "fixture with no golden: ${_stem}" >&2
      _bad=1
    fi
  done
  for _f in "${GOLDEN}"/s43_stage_*.stages; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .stages)"
    if [[ ! -f "${CORPUS}/${_stem}.Dockerfile" ]]; then
      echo "golden with no fixture: ${_stem}" >&2
      _bad=1
    fi
  done
  [[ -d "${CORPUS}" ]] || _bad=1
  (( _bad == 0 ))
}

# ── the stage hash corpus (base#2094, S43a-2 of base#2054) ──────────────────
#
# _compute_dockerfile_hash hashes only the `FROM ... AS <stage>` lines.
# Every corpus/s43/s43_hash_<case>.Dockerfile has one golden
# golden/s43/s43_hash_<case>.hash holding the 64 hex digits plus a trailing
# newline. The function reads <base_path>/Dockerfile, so the fixture is copied
# to ${BATS_TEST_TMPDIR}/<case>/Dockerfile first.

# _check_hash_case <case> -- recompute the hash from the shell and compare it
# byte for byte with the .hash golden.
_check_hash_case() {
  local _name="s43_hash_${1}" _h=""
  [[ -f "${CORPUS}/${_name}.Dockerfile" ]] || {
    echo "fixture missing: ${_name}.Dockerfile" >&2
    return 1
  }
  [[ -f "${GOLDEN}/${_name}.hash" ]] || {
    echo "golden missing: ${_name}.hash" >&2
    return 1
  }
  mkdir -p "${BATS_TEST_TMPDIR}/${1}"
  cp -- "${CORPUS}/${_name}.Dockerfile" "${BATS_TEST_TMPDIR}/${1}/Dockerfile"
  _compute_dockerfile_hash "${BATS_TEST_TMPDIR}/${1}" _h
  printf '%s\n' "${_h}" > "${BATS_TEST_TMPDIR}/${_name}.out"
  cmp -- "${BATS_TEST_TMPDIR}/${_name}.out" "${GOLDEN}/${_name}.hash"
}

# why: three stages is the baseline hash.
@test "s43 hash golden: base3 matches its golden" {
  run _check_hash_case base3
  assert_success
}

# why: adding a stage changes the hash.
@test "s43 hash golden: added matches its golden" {
  run _check_hash_case added
  assert_success
}

# why: a second added stage changes the hash again.
@test "s43 hash golden: two matches its golden" {
  run _check_hash_case two
  assert_success
}

# why: RUN and ENV lines do not change the hash.
@test "s43 hash golden: noise_a matches its golden" {
  run _check_hash_case noise_a
  assert_success
}

# why: other RUN/ENV values and a comment do not change the hash either.
@test "s43 hash golden: noise_b matches its golden" {
  run _check_hash_case noise_b
  assert_success
}

# why: the issue's table gives the expected values as literals; pin them so a
# wrong golden cannot pass by being regenerated the same way.
@test "s43 hash golden: goldens equal the issue's literal digests" {
  run cat "${GOLDEN}/s43_hash_base3.hash"
  assert_output "b63522efeb8407b72dce3bc62cc91a5d5461f833025436584c4d5ffc037a7465"
  run cat "${GOLDEN}/s43_hash_added.hash"
  assert_output "91cd5df58fea8c602dc075ed6f39f9900ab051df7764b99c16c5b85840ee4c03"
  run cat "${GOLDEN}/s43_hash_two.hash"
  assert_output "783f9970e3f6819aa7426e87eb7177cc244a47c0e0638a2b1d609b2133adb0b4"
}

# why: noise lines must not move the hash, so both noise goldens equal base3's.
@test "s43 hash golden: noise goldens are byte-identical to base3" {
  cmp -- "${GOLDEN}/s43_hash_noise_a.hash" "${GOLDEN}/s43_hash_base3.hash"
  cmp -- "${GOLDEN}/s43_hash_noise_b.hash" "${GOLDEN}/s43_hash_base3.hash"
}

# why: a missing Dockerfile is not an error, so the Go side needs the same
# empty result and rc 0.
@test "s43 hash golden: a missing Dockerfile gives empty hash and rc 0" {
  local _h="unset"
  run -0 _compute_dockerfile_hash "${BATS_TEST_TMPDIR}/no_such_dir" _h
  _compute_dockerfile_hash "${BATS_TEST_TMPDIR}/no_such_dir" _h
  [[ -z "${_h}" ]]
}

# why: a hash fixture with no golden, or a golden with no fixture, must fail.
@test "s43 hash golden: every hash fixture has exactly one golden and no extra" {
  local _f _stem _bad=0
  for _f in "${CORPUS}"/s43_hash_*.Dockerfile; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .Dockerfile)"
    if [[ ! -f "${GOLDEN}/${_stem}.hash" ]]; then
      echo "fixture with no golden: ${_stem}" >&2
      _bad=1
    fi
  done
  for _f in "${GOLDEN}"/s43_hash_*.hash; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .hash)"
    if [[ ! -f "${CORPUS}/${_stem}.Dockerfile" ]]; then
      echo "golden with no fixture: ${_stem}" >&2
      _bad=1
    fi
  done
  [[ -d "${CORPUS}" ]] || _bad=1
  (( _bad == 0 ))
}
