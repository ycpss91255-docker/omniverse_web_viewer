#!/usr/bin/env bats
#
# conf/toml_value_spelling_spec.bats -- how lib/conf.sh's
# `_upsert_conf_value` spells a value, a key and a table name in a `.toml`
# file: what is quoted, what stays bare, what is escaped.
#
# why: a value written with the wrong TOML type reads back as something
# else, or as a file the bridge refuses. Every case writes and reads back
# through the bridge.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../test_helper"
  # shellcheck source=dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  TEMP_DIR="$(mktemp -d)"
  TPL=/source/dist/setup.toml
  CONF="${TEMP_DIR}/setup.toml"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# why: `setup.sh set network.mode bridge` is the write the issue was
# filed on: the value has to come out quoted, and it has to land in the
# template's existing `[network]` table rather than open a second one --
# a table declared twice is the other way the bridge refuses the file.
# Booleans and integers stay bare, the way the template spells them.
@test "_upsert_conf_value: a scalar set lands quoted in its existing table, booleans and integers stay bare" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" network mode bridge
  _upsert_conf_value "${CONF}" lifecycle init false
  _upsert_conf_value "${CONF}" logging max_file 7

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'network	mode	bridge'
  assert_line 'lifecycle	init	false'
  assert_line 'logging	max_file	7'

  run grep -c '^\[network\]$' "${CONF}"
  assert_output "1"
  run grep -Fx 'mode = "bridge"' "${CONF}"
  assert_success
  run grep -Fx 'init = false' "${CONF}"
  assert_success
  run grep -Fx 'max_file = 7' "${CONF}"
  assert_success
}

# why: Every field of an array-of-tables entry is string-typed -- the
# bridge joins a volume's source/target/mode with `:` and formats a build
# arg into `key=value` -- so the renderer may not infer a type from the
# text. A numeric named volume (`123:/data`) rendered a bare
# `source = 123`, which handed `str.join` an int: `--kv` raised TypeError
# and the whole configuration stopped loading, not just that one mount.
# A build arg spelled `FEATURE=true` rendered a bare `value = true`, which
# is a TOML boolean and reaches the shell as `true` whatever the
# Dockerfile asked for. The rule is the family's, not one field's.
@test "_upsert_conf_value: array-of-tables fields stay quoted when the text spells an integer or a boolean" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '123:/data'
  _upsert_conf_value "${CONF}" build arg_4 'FEATURE=true'
  _upsert_conf_value "${CONF}" network port_1 '8080:80'
  _upsert_conf_value "${CONF}" image rule_1 '2024'

  run grep -Fx 'source = "123"' "${CONF}"
  assert_success
  run grep -Fx 'value = "true"' "${CONF}"
  assert_success
  run grep -Fx 'host = "8080"' "${CONF}"
  assert_success
  run grep -Fx 'rule = "2024"' "${CONF}"
  assert_success

  # The round trip the quoting exists for: the read gets through at all,
  # and every value arrives as the text that went in.
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_1	123:/data'
  assert_line 'build	arg_4	FEATURE=true'
  assert_line 'network	port_1	8080:80'
  assert_line 'image	rule_1	2024'
}

# why: The same rule one level further IN, on a free-typed TABLE key.
# `_conf_toml_scalar` may infer a type there, so the question is which
# text it may infer one FOR -- and the test is canonical, not valid. TOML
# accepts `-0`, `+1`, `0x10` and `1_000` as integers and reads them as 0,
# 1, 16 and 1000, so a bare render loses the operator's spelling:
# `[environment] env_1 = -0` read back `0`, the sign gone from a value
# someone typed (base#1234). All four are quoted now, and the round trip
# is what says so -- a grep on the file text would pass on a value the
# bridge still reduces.
@test "_upsert_conf_value: a table key that merely looks numeric is quoted and reads back as written" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" environment env_1 '-0'
  _upsert_conf_value "${CONF}" environment env_2 '+1'
  _upsert_conf_value "${CONF}" environment env_3 '0x10'
  _upsert_conf_value "${CONF}" environment env_4 '1_000'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'environment	env_1	-0'
  assert_line 'environment	env_2	+1'
  assert_line 'environment	env_3	0x10'
  assert_line 'environment	env_4	1_000'
}

# why: The control for the rule above, and the half a blanket "quote
# everything" would break. `init = true` / `max_file = 3` is how the
# shipped template spells its own keys, and a table key IS free-typed, so
# the genuine canonical forms have to keep coming back as a boolean and
# an integer rather than as the strings `"true"` and `"3"`. A negative
# integer and a plain `0` are canonical too -- only `-0` is not, because
# only `-0` fails to spell itself back. Driven through the template's own
# keys, so the fixture cannot drift from what ships.
@test "_upsert_conf_value: the template's own booleans and canonical integers stay bare" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" lifecycle init false
  _upsert_conf_value "${CONF}" security privileged true
  _upsert_conf_value "${CONF}" logging max_file 3
  _upsert_conf_value "${CONF}" logging container_log_keep 0
  _upsert_conf_value "${CONF}" logging container_log_days -14

  run grep -Fx 'init = false' "${CONF}"
  assert_success
  run grep -Fx 'privileged = true' "${CONF}"
  assert_success
  run grep -Fx 'max_file = 3' "${CONF}"
  assert_success
  run grep -Fx 'container_log_keep = 0' "${CONF}"
  assert_success
  run grep -Fx 'container_log_days = -14' "${CONF}"
  assert_success

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'lifecycle	init	false'
  assert_line 'security	privileged	true'
  assert_line 'logging	max_file	3'
  assert_line 'logging	container_log_keep	0'
  assert_line 'logging	container_log_days	-14'
}

# why: A per-stage override and a per-service logging override name
# sections and keys TOML cannot spell bare (`stage:headless`,
# `gui.mode`). Quoting them is what keeps the section flat on the way
# back, so `_conf_split_nskey`'s rule still applies to what the bridge
# emits.
@test "_upsert_conf_value: a section or key that is not a bare TOML name is quoted and reads back flat" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" stage:headless gui.mode off

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'stage:headless	gui.mode	off'
  run grep -Fx '["stage:headless"]' "${CONF}"
  assert_success
  run grep -Fx '"gui.mode" = "off"' "${CONF}"
  assert_success
}

# why: A value carrying a double quote or a backslash is the one that
# turns a naive `"%s"` into a file the bridge refuses (`\c` is not a
# TOML escape). Escaped, it round-trips to the byte the user typed.
@test "_upsert_conf_value: quotes and backslashes in a value are escaped and read back verbatim" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" environment env_1 'Q=a"b\c'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'environment	env_1	Q=a"b\c'
}
