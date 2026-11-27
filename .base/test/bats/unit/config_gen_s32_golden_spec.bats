#!/usr/bin/env bats
#
# config_gen_s32_golden_spec.bats -- the s32 corpus of the INI-to-TOML
# converter, pinned as goldens (base#2056, slice S32a of base#1765).
#
# why: The Go converter that replaces `_migrate_ini_to_toml` must match the
# shell byte for byte. Each corpus/s32/<name>.ini is converted by the shell
# into a temp dir; the resulting setup.toml must equal the committed
# golden/s32/<name>.toml, the event ids the shell logs must equal the list
# below, and the function's return must be 0. The spec fails while a golden
# is missing or differs, so a golden can never drift from the shell.

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"
TESTDATA="/source/dockerfile/config-gen/testdata"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _check_s32 <name> <event ids, space separated>
#   Convert corpus/s32/<name>.ini with the shell, then compare the bytes of
#   the written setup.toml with golden/s32/<name>.toml, the logged event ids
#   (JSON log body, in order) with the expected list, and the return with 0.
_check_s32() {
  local _name="${1}" _events="${2}" _got
  cp "${TESTDATA}/corpus/s32/${_name}.ini" "${TEMP_DIR}/.setup.conf"
  LOG_FORMAT=json run --separate-stderr bash -c \
    "source '${LIB}/_lib.sh'; source '${LIB}/ini_to_toml_migrate.sh'; _migrate_ini_to_toml '${TEMP_DIR}'"
  assert_success
  _got="$(printf '%s\n%s\n' "${output}" "${stderr}" \
    | sed -n 's/.*"body":"\([a-z_]*\)".*/\1/p' | paste -sd' ')"
  assert_equal "${_got}" "${_events}"
  assert [ -f "${TESTDATA}/golden/s32/${_name}.toml" ]
  run cmp "${TEMP_DIR}/setup.toml" "${TESTDATA}/golden/s32/${_name}.toml"
  assert_success
}

# why: A key written twice converts to one line holding the last value;
# the golden pins the bytes and the single migrated event.
@test "s32 a repeated key keeps the last value (base#2056)" {
  _check_s32 s32_repeat_key "ini_to_toml_migrated"
}

# why: String values are quoted and plain integers stay bare; the golden
# pins the bytes.
@test "s32 scalar values quote strings and keep plain integers bare (base#2056)" {
  _check_s32 s32_scalar_values "ini_to_toml_migrated"
}

# why: A backslash and a literal TAB inside a value are escaped in the
# quoted string; the golden pins the bytes.
@test "s32 backslash and tab are escaped in the quoted string (base#2056)" {
  _check_s32 s32_backslash_tab "ini_to_toml_migrated"
}

# why: A section with no numbered families converts by itself; the golden
# pins the bytes.
@test "s32 a section without numbered families converts alone (base#2056)" {
  _check_s32 s32_absent_family "ini_to_toml_migrated"
}

# why: The deploy runtime key is written as gpu_runtime; the shell logs the
# rename event before the migrated event, and the golden pins the bytes.
@test "s32 deploy runtime is renamed to gpu_runtime (base#2056)" {
  _check_s32 s32_runtime_alias "ini_to_toml_runtime_renamed ini_to_toml_migrated"
}

# why: A gap in the numbered keys leaves an empty block for the missing
# number; the golden pins the bytes.
@test "s32 a gap in numbered keys leaves an empty block (base#2082)" {
  _check_s32 s32_gap "ini_to_toml_migrated"
}

# why: A numbered key with an empty value still takes its slot as an empty
# block; the golden pins the bytes.
@test "s32 an emptied slot keeps an empty block (base#2082)" {
  _check_s32 s32_emptied_slot "ini_to_toml_migrated"
}

# why: Numbered keys are ordered by their numeric suffix, not by file order
# or string order; the golden pins the bytes.
@test "s32 numbered keys are ordered by numeric suffix (base#2082)" {
  _check_s32 s32_suffix_order "ini_to_toml_migrated"
}

# why: The numbered-key family of image_rules converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 image rules become an array of tables (base#2087)" {
  _check_s32 s32_image_rules "ini_to_toml_migrated"
}

# why: The numbered-key family of build_args converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 build args split into key and value tables (base#2087)" {
  _check_s32 s32_build_args "ini_to_toml_migrated"
}

# why: The numbered-key family of volumes converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 a volume mount splits into source, target and mode (base#2087)" {
  _check_s32 s32_volumes "ini_to_toml_migrated"
}

# why: The numbered-key family of security converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 cap_add and security_opt become arrays of tables (base#2087)" {
  _check_s32 s32_security "ini_to_toml_migrated"
}

# why: The numbered-key family of network_ports converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 network ports split into host and container (base#2087)" {
  _check_s32 s32_network_ports "ini_to_toml_migrated"
}

# why: The numbered-key family of devices converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 devices and cgroup rules become arrays of tables (base#2087)" {
  _check_s32 s32_devices "ini_to_toml_migrated"
}

# why: The numbered-key family of tmpfs converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 a tmpfs entry becomes an array of tables (base#2087)" {
  _check_s32 s32_tmpfs "ini_to_toml_migrated"
}

# why: The numbered-key family of contexts converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 an additional context splits into name and source (base#2087)" {
  _check_s32 s32_contexts "ini_to_toml_migrated"
}

# why: The numbered-key family of environment converts as the shell does; the golden
# pins the bytes and the single migrated event.
@test "s32 environment numbered keys stay plain keys (base#2087)" {
  _check_s32 s32_environment "ini_to_toml_migrated"
}

# _check_s32_declined <name>
#   Convert corpus/s32/<name>.ini with the shell. A declined input writes no
#   setup.toml, keeps .setup.conf unchanged, logs exactly one event id and
#   returns 1. The golden golden/s32/<name>.declined holds two lines: the
#   event id, then the exit code 1. The shell's event id and return are
#   re-derived here and must equal both lines.
_check_s32_declined() {
  local _name="${1}" _got _event _rc
  cp "${TESTDATA}/corpus/s32/${_name}.ini" "${TEMP_DIR}/.setup.conf"
  LOG_FORMAT=json run --separate-stderr bash -c \
    "source '${LIB}/_lib.sh'; source '${LIB}/ini_to_toml_migrate.sh'; _migrate_ini_to_toml '${TEMP_DIR}'"
  _rc="${status}"
  _got="$(printf '%s\n%s\n' "${output}" "${stderr}" \
    | sed -n 's/.*"body":"\([a-z_]*\)".*/\1/p' | paste -sd' ')"
  assert [ ! -e "${TEMP_DIR}/setup.toml" ]
  run cmp "${TEMP_DIR}/.setup.conf" "${TESTDATA}/corpus/s32/${_name}.ini"
  assert_success
  assert [ -f "${TESTDATA}/golden/s32/${_name}.declined" ]
  _event="$(sed -n 1p "${TESTDATA}/golden/s32/${_name}.declined")"
  assert_equal "${_got}" "${_event}"
  assert_equal "${_rc}" "$(sed -n 2p "${TESTDATA}/golden/s32/${_name}.declined")"
  assert_equal "$(wc -l < "${TESTDATA}/golden/s32/${_name}.declined")" "2"
}

# why: An index with leading zeros cannot be represented; the converter
# declines, keeps .setup.conf and logs one event id.
@test "s32 a padded index is declined (base#2085)" {
  _check_s32_declined s32_padded_index
}

# why: Index 0 cannot be represented; the converter declines.
@test "s32 a zero index is declined (base#2085)" {
  _check_s32_declined s32_zero_index
}

# why: The same index written twice is declined as a duplicate index.
@test "s32 a duplicate index is declined (base#2085)" {
  _check_s32_declined s32_duplicate_index
}

# why: Filling then clearing the same index is declined as a duplicate index.
@test "s32 clearing an index after filling it is declined (base#2085)" {
  _check_s32_declined s32_clear_after_fill
}
