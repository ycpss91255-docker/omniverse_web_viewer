#!/usr/bin/env bats
#
# config_gen_s43_from_golden_spec.bats -- the s43 FROM-line grammar corpus
# against the `.stages` and `.hash` goldens (base#2095, S43a-3 of base#2054).
#
# why: Before any Go parser exists, the shell `_dockerfile_stage_from_line`
# (dist/script/docker/lib/stage.sh) is the oracle for which FROM lines are
# accepted. Each dockerfile/config-gen/testdata/corpus/s43/s43_from_<case>.Dockerfile
# holds exactly one FROM-relevant line plus optional lint-allow comment lines.
# Its goldens in testdata/golden/s43/ are
# s43_from_<case>.stages (stdout of `_parse_dockerfile_stages`, empty output is
# a 0-byte file) and s43_from_<case>.hash (`_compute_dockerfile_hash` plus a
# trailing newline). The Go side must later match these byte for byte. The
# spec regenerates both from the shell and compares them with the goldens, and
# a partition check keeps fixtures and goldens one-to-one.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
  TESTDATA="/source/dockerfile/config-gen/testdata"
  CORPUS="${TESTDATA}/corpus/s43"
  GOLDEN="${TESTDATA}/golden/s43"
  # sha256 of the empty string: no FROM line was accepted.
  EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}

# _check_case <case> -- regenerate .stages and .hash of s43_from_<case>.Dockerfile
# from the shell and compare each byte for byte with its golden.
_check_case() {
  local _name="s43_from_${1}"
  local _ext _g
  [[ -f "${CORPUS}/${_name}.Dockerfile" ]] || {
    echo "fixture missing: ${_name}.Dockerfile" >&2
    return 1
  }
  for _ext in stages hash; do
    [[ -f "${GOLDEN}/${_name}.${_ext}" ]] || {
      echo "golden missing: ${_name}.${_ext}" >&2
      return 1
    }
  done
  _parse_dockerfile_stages "${CORPUS}/${_name}.Dockerfile" > "${BATS_TEST_TMPDIR}/${_name}.stages"
  cmp -- "${BATS_TEST_TMPDIR}/${_name}.stages" "${GOLDEN}/${_name}.stages" || return 1
  # _compute_dockerfile_hash reads <base>/Dockerfile.
  mkdir -p "${BATS_TEST_TMPDIR}/${_name}.d"
  cp -- "${CORPUS}/${_name}.Dockerfile" "${BATS_TEST_TMPDIR}/${_name}.d/Dockerfile"
  _compute_dockerfile_hash "${BATS_TEST_TMPDIR}/${_name}.d" _g
  printf '%s\n' "${_g}" > "${BATS_TEST_TMPDIR}/${_name}.hash"
  cmp -- "${BATS_TEST_TMPDIR}/${_name}.hash" "${GOLDEN}/${_name}.hash"
}

# ── accepted FROM lines ─────────────────────────────────────────────────────

# why: the plain `FROM <image> AS <stage>` form is accepted.
@test "s43 from golden: plain lists runtime" {
  run _check_case plain
  assert_success
}

# why: one --flag=value before the image is accepted.
@test "s43 from golden: platform lists runtime" {
  run _check_case platform
  assert_success
}

# why: several flags before the image are accepted.
@test "s43 from golden: multiflag lists runtime" {
  run _check_case multiflag
  assert_success
}

# ── rejected lines ──────────────────────────────────────────────────────────

# why: a lowercase `as` is not accepted.
@test "s43 from golden: lower rejects lowercase as" {
  run _check_case lower
  assert_success
}

# why: a commented FROM is not accepted.
@test "s43 from golden: comment rejects a commented FROM" {
  run _check_case comment
  assert_success
}

# why: an extra word between the image and AS is not accepted.
@test "s43 from golden: bare rejects a junk word" {
  run _check_case bare
  assert_success
}

# why: an inline comment before AS is not accepted.
@test "s43 from golden: inline rejects an inline comment" {
  run _check_case inline
  assert_success
}

# why: a flag standing in for the image is not accepted.
@test "s43 from golden: flagimage rejects a flag as image" {
  run _check_case flagimage
  assert_success
}

# why: an indented FROM is not accepted.
@test "s43 from golden: indented rejects leading spaces" {
  run _check_case indented
  assert_success
}

# why: COPY --from is not a FROM line.
@test "s43 from golden: copyfrom rejects COPY --from" {
  run _check_case copyfrom
  assert_success
}

# ── literal expectations, independent of the goldens ────────────────────────

# why: the issue's table gives the expected hashes; pin them as literals so a
# wrong golden cannot pass by being regenerated the same way.
@test "s43 from golden: accepted cases carry the issue's hash literals" {
  run cat "${GOLDEN}/s43_from_plain.hash"
  assert_success
  assert_output "0f5afd01306e98a2124730d3bd49356b062d064f94b6a027781da69ffda75d4a"
  run cat "${GOLDEN}/s43_from_platform.hash"
  assert_success
  assert_output "7eaed3e9ed5f04b49ad286227ac8c5f29f5be17fae2cc62a5de280515cea6db8"
  run cat "${GOLDEN}/s43_from_multiflag.hash"
  assert_success
  assert_output "60d10aa8564ddde99d94c666c6cac793048918ffeb041a13ab297345e4812a32"
}

# why: every rejected case hashes to the empty-string sha256 and lists no stage.
@test "s43 from golden: rejected cases hash to the empty sha256 with a 0-byte stages" {
  local _c
  for _c in lower comment bare inline flagimage indented copyfrom; do
    run cat "${GOLDEN}/s43_from_${_c}.hash"
    assert_success
    assert_output "${EMPTY_SHA}"
    [[ -f "${GOLDEN}/s43_from_${_c}.stages" ]]
    [[ ! -s "${GOLDEN}/s43_from_${_c}.stages" ]]
  done
}

# why: accepted cases list exactly the stage runtime.
@test "s43 from golden: accepted cases list runtime" {
  local _c
  for _c in plain platform multiflag; do
    run cat "${GOLDEN}/s43_from_${_c}.stages"
    assert_success
    assert_output "runtime"
  done
}

# ── the partition check ─────────────────────────────────────────────────────

# why: a fixture missing a .stages or .hash golden, or a golden with no
# fixture, must fail the spec so the corpus cannot drift from its goldens.
@test "s43 from golden: every fixture has exactly one .stages and one .hash and no extra" {
  local _f _stem _bad=0 _ext
  for _f in "${CORPUS}"/s43_from_*.Dockerfile; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" .Dockerfile)"
    for _ext in stages hash; do
      if [[ ! -f "${GOLDEN}/${_stem}.${_ext}" ]]; then
        echo "fixture with no ${_ext} golden: ${_stem}" >&2
        _bad=1
      fi
    done
  done
  for _f in "${GOLDEN}"/s43_from_*.stages "${GOLDEN}"/s43_from_*.hash; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f%.*}")"
    if [[ ! -f "${CORPUS}/${_stem}.Dockerfile" ]]; then
      echo "golden with no fixture: $(basename -- "${_f}")" >&2
      _bad=1
    fi
  done
  [[ -d "${CORPUS}" ]] || _bad=1
  (( _bad == 0 ))
}
