#!/usr/bin/env bats
#
# conf/toml_array_entry_spec.bats -- how lib/conf.sh's
# `_upsert_conf_value` writes a numbered key (`<prefix>_N`) as entry N of
# an array of tables in a `.toml` file.
#
# why: entry N of the array IS the key `<prefix>_N`, so a write has to land
# at the index it names with every field in its place. Every case reads
# the file back through the bridge.

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

# why: The first write every downstream repo ever sees: setup_detect.sh
# copies the shipped template and upserts `[volumes] mount_1`. If that
# file does not parse, nothing after bootstrap does. The value carries
# `${WS_PATH}` literally, so this also pins that the writer quotes rather
# than expands.
@test "_upsert_conf_value: the mount_1 bootstrap write on the shipped template parses through the bridge and reads back" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  # shellcheck disable=SC2016  # literal ${WS_PATH} / ${USER_NAME} intentional
  _upsert_conf_value "${CONF}" volumes mount_1 '${WS_PATH}:/home/${USER_NAME}/work'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  # shellcheck disable=SC2016
  assert_line 'volumes	mount_1	${WS_PATH}:/home/${USER_NAME}/work'
}

# why: Index N of the array IS the key `<prefix>_N`, so a write naming an
# index past the end has to LAND there. Appending one block gave it the
# next position under a different name, and on the shipped template --
# whose `[volumes]` holds no block at all -- `setup.sh set volumes.mount_2
# /data:/data` read back as `mount_1`, the workspace bind.
# `_reconcile_workspace_path` honours an existing absolute source at
# `mount_1` as a deliberately pinned workspace, so WS_PATH silently became
# the operator's data directory. The INI writer had no such failure: it
# wrote the key `mount_2` and left `mount_1` absent. The positions in
# between are padded field-less, the same rule and the same spelling the
# converter's dense emission already uses. Driven on the shipped template,
# because that no-blocks state is the seeded state of every downstream
# repo rather than an edge case.
@test "_upsert_conf_value: a write past the end of an array lands at the index it named" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_3 '/data:/data'

  # Two field-less blocks stand in front of it, so the value is entry 3.
  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "3"

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_3	/data:/data'
  # The workspace slot is NOT what the write landed in, and it reads back
  # empty rather than as the bogus `:` no list reader skips.
  refute_line --regexp '^volumes	mount_1	.'
  refute_line --regexp '^volumes	mount_2	.'

  # And the next write still addresses the padded slots by name.
  _upsert_conf_value "${CONF}" volumes mount_2 '/srv:/srv:ro'
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_2	/srv:/srv:ro'
  assert_line 'volumes	mount_3	/data:/data'
  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "3"
}

# why: The conversion table of the migration: a numbered list key is an
# `[[array of tables]]` entry, not a `mount_N` scalar. The N-th block IS
# entry N, so writing an index that exists replaces that block in place
# and writing the next index appends a block after it; the bridge
# numbers them back in file order. `build arg_4` on a template whose
# `[[build.args]]` holds three is the next position, so it needs no
# padding -- which is what separates it from the test above.
@test "_upsert_conf_value: numbered keys land as array-of-tables entries that the bridge numbers back" {
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '/a:/b'
  _upsert_conf_value "${CONF}" volumes mount_2 '/c:/d:ro'
  _upsert_conf_value "${CONF}" volumes mount_1 '/x:/y'
  _upsert_conf_value "${CONF}" build arg_4 'FOO=bar'
  _upsert_conf_value "${CONF}" network port_1 '8080:80'
  _upsert_conf_value "${CONF}" image rule_2 'suffix:_dev'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_1	/x:/y'
  assert_line 'volumes	mount_2	/c:/d:ro'
  assert_line 'build	arg_3	TZ=Asia/Taipei'
  assert_line 'build	arg_4	FOO=bar'
  assert_line 'network	port_1	8080:80'
  assert_line 'image	rule_1	prefix:docker_'
  assert_line 'image	rule_2	suffix:_dev'
  assert_line 'image	rule_3	@basename'

  run grep -c '^\[\[volumes\]\]$' "${CONF}"
  assert_output "2"
  run grep -c '^\[\[build.args\]\]$' "${CONF}"
  assert_output "4"
  run grep -c '^\[\[image.rules\]\]$' "${CONF}"
  assert_output "3"
  run grep -c '^mount_' "${CONF}"
  assert_output "0"
}

# why: An array-of-tables entry is ONE string on the shell side. The
# writer splits it textually and the bridge's array spec glued the halves
# back unconditionally, so an entry that had only ONE side came back
# carrying a separator the operator never wrote. The two are different
# settings, not two spellings of one: `--build-arg HTTP_PROXY` inherits
# the value from the build environment while `--build-arg HTTP_PROXY=`
# sets it to the empty string, and `80` is a published port where `80:`
# is not a mapping compose accepts at all. Neither half of the seam can
# carry the rule alone -- a writer that renders the absent half leaves
# `value = ""` indistinguishable from a deliberate trailing `=`, and a
# reader that keeps manufacturing the separator undoes a writer that
# omitted it -- so the distinction is FIELD PRESENCE in the written TOML,
# absent meaning the operator wrote no second half. Asserted through the
# bridge rather than over the file text, which looks correct whichever
# way it reads back.
@test "_upsert_conf_value: a one-sided array entry round-trips without gaining a separator" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" build   arg_4   'HTTP_PROXY'
  _upsert_conf_value "${CONF}" build   arg_5   'HTTPS_PROXY='
  _upsert_conf_value "${CONF}" network port_1  '80'
  _upsert_conf_value "${CONF}" network port_2  '8080:80'

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'build	arg_4	HTTP_PROXY'
  assert_line 'build	arg_5	HTTPS_PROXY='
  assert_line 'network	port_1	80'
  assert_line 'network	port_2	8080:80'
}

# why: `volumes` was believed to escape the one-sided glue because its
# serialiser joins only the TRUTHY parts, but truthiness is the wrong
# test for a THREE-field entry: the writer emits `target` whenever the
# first colon is there and `mode` whenever the second is, empty or not,
# so a read-only mount with no container half (`/srv/data::ro`) came back
# as `/srv/data:ro` -- the mode SHIFTED into the target position, which
# mounts the host directory at the path `ro`. Presence rather than
# truthiness is what keeps a field's position, and it is the same rule
# the two-field families need, so there is one spelling of it rather than
# two.
@test "_upsert_conf_value: an empty middle field keeps its position instead of shifting the mode into it" {
  assert_spec_subject "${TPL}" "the shipped setup.toml template"
  cp "${TPL}" "${CONF}"
  _upsert_conf_value "${CONF}" volumes mount_1 '/srv/data::ro'
  _upsert_conf_value "${CONF}" volumes mount_2 '/srv/cache:'
  _upsert_conf_value "${CONF}" volumes mount_3 '/a:/b:rw'
  _upsert_conf_value "${CONF}" volumes mount_4 ''

  run toml_bridge_parse "${CONF}" --kv
  assert_success
  assert_line 'volumes	mount_1	/srv/data::ro'
  assert_line 'volumes	mount_2	/srv/cache:'
  assert_line 'volumes	mount_3	/a:/b:rw'
  # The other side of the rule: an entry whose fields are ALL empty is
  # the operator's opt-out -- the published way to clear the workspace
  # mount -- and must stay an empty value rather than become the bare
  # `:` that `_conf_list_sorted` does not skip.
  assert_line 'volumes	mount_4	'
}

# why: Index N of the array IS the key `<prefix>_N`, and the writer
# addresses a block by its POSITION, so a suffix that is not the plain
# decimal spelling of a position lands somewhere else under a different
# name. Measured on the shipped template, whose `[volumes]` holds no
# block: `set volumes.mount_0` and `set volumes.mount_01` each wrote one
# block that read back as `mount_1` -- the workspace bind, whose existing
# absolute source `_reconcile_workspace_path` honours as a pinned
# workspace. The converter already declines both shapes by name for the
# same reason; this is the writer getting the same check. Refused before
# the temp file exists, so the original is untouched, which is what the
# second parse of each case asserts.
@test "_upsert_conf_value: an index with no 1-based slot is refused, not rerouted" {
  cp "${TPL}" "${CONF}"
  LOG_FORMAT=json run --separate-stderr _upsert_conf_value "${CONF}" volumes mount_0 '/data:/data'
  assert_refusal 1 conf_write_index_rejected "file=${CONF}" section=volumes key=mount_0
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  refute_line --regexp '^volumes	mount_1	.'

  cp "${TPL}" "${CONF}"
  LOG_FORMAT=json run --separate-stderr _upsert_conf_value "${CONF}" volumes mount_01 '/pad:/pad'
  assert_refusal 1 conf_write_index_rejected "file=${CONF}" section=volumes key=mount_01
  run toml_bridge_parse "${CONF}" --kv
  assert_success
  refute_line --regexp '^volumes	mount_1	.'
}
