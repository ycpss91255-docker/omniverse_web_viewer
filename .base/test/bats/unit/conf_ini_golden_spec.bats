#!/usr/bin/env bats
#
# conf_ini_golden_spec.bats -- the INI corpus held to recorded bytes
# (base#2053, S25a under base#1757).
#
# why: `_ini_tokenize` is the single shell INI tokenizer. The Go reader
# that replaces it (the later `ini tokens` slice) must match it byte for
# byte, so the shell's answer for every corpus input is recorded once in
# dockerfile/config-gen/testdata/golden/s25/<stem>.tokens.golden and this
# spec holds the shell to that record. A golden is tab-separated lines:
# `section<TAB><name>` per section, then
# `entry<TAB><section><TAB><key><TAB><value>` per entry.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  CORPUS=/source/dockerfile/config-gen/testdata/corpus/s25
  GOLDEN=/source/dockerfile/config-gen/testdata/golden/s25
}

# _tokens_of <file> -- print the golden-format rendering of what
# _ini_tokenize reads from <file>.
_tokens_of() {
  local -a _s=() _es=() _k=() _v=()
  local _i
  _ini_tokenize "${1}" _s _es _k _v
  for _i in "${!_s[@]}"; do
    printf 'section\t%s\n' "${_s[_i]}"
  done
  for _i in "${!_k[@]}"; do
    printf 'entry\t%s\t%s\t%s\n' "${_es[_i]}" "${_k[_i]}" "${_v[_i]}"
  done
}

# why: a corpus input added or dropped without a golden changes what the
# Go reader is held to; the count makes that a visible edit.
@test "the s25 corpus holds its eight inputs" {
  local -a _f=("${CORPUS}"/s25_[!lb]*.ini)
  assert_equal "${#_f[@]}" "8"
}

# why: an input without a golden is compared against nothing, and a golden
# without an input is a record of nothing.
@test "every s25 input has a golden, and no golden is orphaned" {
  local _f _g _stem _missing="" _orphan=""
  for _f in "${CORPUS}"/s25_[!lb]*.ini; do
    _stem="$(basename "${_f}" .ini)"
    [[ -s "${GOLDEN}/${_stem}.tokens.golden" ]] || _missing+=" ${_stem}"
  done
  for _g in "${GOLDEN}"/*.tokens.golden; do
    [[ -f "${_g}" ]] || continue
    _stem="$(basename "${_g}" .tokens.golden)"
    [[ -f "${CORPUS}/${_stem}.ini" ]] || _orphan+=" ${_stem}"
  done
  [[ -z "${_missing}${_orphan}" ]] || {
    echo "inputs without a non-empty golden:${_missing}" >&2
    echo "goldens without an input:${_orphan}" >&2
    return 1
  }
}

# why: this is the record itself: the shell answer the Go reader must
# reproduce byte for byte.
@test "_ini_tokenize over every s25 input matches its golden byte for byte" {
  local _f _stem _bad=""
  for _f in "${CORPUS}"/s25_[!lb]*.ini; do
    _stem="$(basename "${_f}" .ini)"
    if ! cmp -s <(_tokens_of "${_f}") "${GOLDEN}/${_stem}.tokens.golden"; then
      _bad+=" ${_stem}"
    fi
  done
  [[ -z "${_bad}" ]] || {
    echo "differs from golden:${_bad}" >&2
    return 1
  }
}

# why: `_dump_conf_section` is the shell answer the later `ini dump-section`
# slice must reproduce (base#2058, S25b). The <stem>:<section> pairs below
# are written out by hand from the corpus files, not derived by the code
# under test; the goldens are the exact stdout bytes, one file per pair.
# A colon in a section name is written `%3A` in the golden file name,
# because Windows cannot create a file whose name holds a colon.
@test "_dump_conf_section over every s25 input and section matches its golden byte for byte" {
  local _pair _stem _sec _file_sec _bad=""
  local -a _pairs=(
    "s25_comments:image" "s25_comments:build"
    "s25_keys_before_header:image"
    "s25_repeated_sections:a" "s25_repeated_sections:b"
    "s25_repeated_keys:a"
    "s25_dotted_keys:stage:dev"
    "s25_equals_in_value:environment"
    "s25_empty_values:deploy"
    "s25_no_trailing_newline:image" "s25_no_trailing_newline:build"
  )
  for _pair in "${_pairs[@]}"; do
    _stem="${_pair%%:*}"
    _sec="${_pair#*:}"
    _file_sec="${_sec//:/%3A}"
    if ! cmp -s <(_dump_conf_section "${CORPUS}/${_stem}.ini" "${_sec}") \
      "${GOLDEN}/${_stem}.dump.${_file_sec}.golden"; then
      _bad+=" ${_stem}:${_sec}"
    fi
  done
  [[ -z "${_bad}" ]] || {
    echo "differs from golden:${_bad}" >&2
    return 1
  }
}

# _load_of <handle> -- print the golden-format rendering of the sections
# and entries _conf_load_layers left in <handle>.
_load_of() {
  local -n _ls="${1}__sects" _le="${1}__es" _lk="${1}__keys" _lv="${1}__vals"
  local _i
  for _i in "${!_ls[@]}"; do
    printf 'section\t%s\n' "${_ls[_i]}"
  done
  for _i in "${!_lk[@]}"; do
    printf 'entry\t%s\t%s\t%s\n' "${_le[_i]}" "${_lk[_i]}" "${_lv[_i]}"
  done
}

# why: `_conf_load_layers` over a two-layer INI chain is section-replace
# (base#2062, S25c): the upper layer owns section `a`, so `a|y|2` from the
# base layer must not survive. The expected bytes are in
# golden/s25/layers.base_over.golden; the absent third path adds nothing.
@test "_conf_load_layers over the base and over layers matches layers.base_over.golden" {
  local _rc=0
  _conf_load_layers H "${CORPUS}/s25_layer_base.ini" \
    "${CORPUS}/s25_layer_over.ini" "${CORPUS}/s25_layer_absent.ini" || _rc=$?
  assert_equal "${_rc}" "0"
  cmp -s <(_load_of H) "${GOLDEN}/layers.base_over.golden" || {
    echo "differs from layers.base_over.golden" >&2
    return 1
  }
}

# why: `_conf_load_layers` over a single file is the tokenizer's sections
# with entries grouped by section; each single-file corpus input has its
# own <stem>.load.golden.
@test "_conf_load_layers over every single s25 input matches its load golden" {
  local _f _stem _bad=""
  for _f in "${CORPUS}"/s25_[!lb]*.ini; do
    _stem="$(basename "${_f}" .ini)"
    _conf_load_layers H "${_f}"
    if ! cmp -s <(_load_of H) "${GOLDEN}/${_stem}.load.golden"; then
      _bad+=" ${_stem}"
    fi
  done
  [[ -z "${_bad}" ]] || {
    echo "differs from golden:${_bad}" >&2
    return 1
  }
}

# why: `_setup_conf_merge_blockers` is the shell answer the later
# `ini blockers` slice must reproduce (base#2066, S25d). Over the
# s25_blockers_* trio the expected blockers are `a` (root differs from
# legacy and from the template) and `d` (only the root has it), in that
# order; `b` (legacy and root agree) and `c` (root equals the template)
# are not. The bytes are in golden/s25/blockers.golden.
@test "_setup_conf_merge_blockers over the s25 blockers trio matches blockers.golden" {
  # shellcheck source=dist/script/docker/lib/setup_conf_migrate.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/setup_conf_migrate.sh
  local -a _out=()
  local _rc=0
  _conf_load_layers L "${CORPUS}/s25_blockers_legacy.ini"
  _conf_load_layers R "${CORPUS}/s25_blockers_root.ini"
  _conf_load_layers T "${CORPUS}/s25_blockers_tmpl.ini"
  _setup_conf_merge_blockers L R T _out || _rc=$?
  assert_equal "${_rc}" "0"
  cmp -s <(printf '%s\n' ${_out[@]+"${_out[@]}"}) "${GOLDEN}/blockers.golden" || {
    echo "differs from blockers.golden" >&2
    return 1
  }
}
