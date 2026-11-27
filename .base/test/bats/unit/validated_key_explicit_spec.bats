#!/usr/bin/env bats
#
# validated_key_explicit_spec.bats -- the explicit cases beside
# validated_key_reach_spec.bats's derived gate: keys the schema accepts
# whose value reaches one tier and not the other, or is overruled by
# another key.
#
# why: a reachability check cannot see a value that reaches one tier and
# not the other, or one another key silently overrules; each case below
# pins one such key on the dev compose and the field-deploy bundle.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/validated_key_reach_helper"

# ════════════════════════════════════════════════════════════════════
# base#1094 (1): [network] pid = container:<name>
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 1 -- `_validate_pid_mode` accepts
# `container:<name>` and the TUI offers it, while both emitters wrote
# `pid:` only when the value was exactly `host`. A user who set
# `container:foo` got a green config and a compose file with no `pid:`
# line at all. `private` stays omitted on purpose: Docker rejects it as a
# literal and omitting the key gives the same private namespace.
@test "pid = container:<name> reaches the dev compose, and private still does not (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_out}" myrepo \
      false false 0 gpu _extras "" "" "" "" "" "" host host 'container:probe0' )
  run grep -cE '^    pid: ' "${_out}"
  assert_output "1"

  local _priv="${TEMP_DIR}/private.yaml" _extras2=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_priv}" myrepo \
      false false 0 gpu _extras2 "" "" "" "" "" "" host host private )
  run grep -cE '^    pid: ' "${_priv}"
  assert_output "0"
}

# why: base#1094 item 1, field tier. The bundle writes literals rather
# than `${PID_MODE}`, so the value itself has to arrive -- a bundle that
# merely carried the key would be no use to the device.
@test "pid = container:<name> reaches the field bundle as a literal (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[pid_mode]}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run grep -F 'pid: container:probe0' "${TEMP_DIR}/field.yaml"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (2): [resources] shm_size under the shipped ipc = host
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 2 -- the shipped template sets `ipc = "host"`, and
# both emitters drop `shm_size` unless ipc is something else. So the
# DEFAULT configuration makes the only key in `[resources]` do nothing.
# `ports` has the identical situation under `mode = host` and has printed
# a diagnostic for it since base#879; this one printed nothing. The fix is
# the same diagnostic, not a default change (ADR-00000019 chose the host
# defaults deliberately).
@test "a shm_size dropped under ipc = host is reported by the dev emitter (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    '' '' '' '' '' '2g' host host private 2>&1"
  assert_success
  assert_output --partial "honours shm_size only when ipc is not host"
  run grep -c 'shm_size' "${_out}"
  assert_output "0"
}

@test "a shm_size that is emitted under a non-host ipc is not reported (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml"
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    '' '' '' '' '' '2g' host shareable private 2>&1"
  assert_success
  refute_output --partial "honours shm_size only when ipc is not host"
  run grep -cF 'shm_size: 2g' "${_out}"
  assert_output "1"
}

# why: base#1094 item 2 -- the diagnostic has to fire where the user can
# act on it, which is also when the value is stored. The ports precedent
# (base#879) fires at both points and so does this.
@test "setting resources.shm_size under the shipped ipc = host warns at store time (base#1094)" {
  local _d
  _d="$(_conf_dir '[network]
ipc = "host"
')"
  run bash /source/dist/script/docker/wrapper/setup.sh set resources.shm_size 2g --base-path "${_d}"
  assert_success
  assert_output --partial "honours shm_size only when ipc is not host"
}

@test "setting resources.shm_size under a non-host ipc stays quiet (base#1094)" {
  local _d
  _d="$(_conf_dir '[network]
ipc = "shareable"
')"
  run bash /source/dist/script/docker/wrapper/setup.sh set resources.shm_size 2g --base-path "${_d}"
  assert_success
  refute_output --partial "honours shm_size only when ipc is not host"
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (3): [network] mode beside a network_name
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 3 -- two keys answered one question and the loser
# was silent. Three of the five emission sites already agreed that mode
# decides and `network_name` only applies under bridge (the per-stage
# service emitter, and both branches of the field bundle); the devel
# service and the top-level `networks:` declaration consulted only
# `network_name`. So one setup.toml produced bridge networking in
# development and host networking on the device, with nothing said. The
# devel service now follows the same rule as its own siblings.
@test "mode = host beside a network_name keeps host networking in the dev compose (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_out}" myrepo \
      false false 0 gpu _extras mynet "" "" "" "" "" host host private ) >/dev/null 2>&1
  run grep -cE '^    network_mode: ' "${_out}"
  assert_output "1"
  run grep -c '^networks:$' "${_out}"
  assert_output "0"
}

@test "mode = bridge beside a network_name still joins the named network (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  ( cd "${TEMP_DIR}" && generate_compose_yaml "${_out}" myrepo \
      false false 0 gpu _extras mynet "" "" "" "" "" bridge host private ) >/dev/null 2>&1
  run grep -cF '      - mynet' "${_out}"
  assert_output "1"
  run grep -c '^networks:$' "${_out}"
  assert_output "1"
}

# why: base#1094 item 3, the case a global-mode reading gets wrong. A
# `[stage:<name>]` override can set network.mode = "bridge" while the
# global mode is host: that stage joins the inherited name, so the
# top-level declaration has to be there or compose refuses the whole
# project for referencing an undeclared network. The declaration is
# therefore driven by what the service blocks EMITTED, not by
# re-deriving the condition from the global mode -- a second derivation
# of one question being the family base#1094 belongs to.
@test "a stage overriding mode to bridge still gets its named network declared (base#1094)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS probe
DOCK
  cat > "${TEMP_DIR}/setup.toml" <<'CONF'
[network]
mode = "host"
network_name = "mynet"

["stage:probe"]
"network.mode" = "bridge"
CONF
  local _out="${TEMP_DIR}/compose.yaml" _extras=()
  generate_compose_yaml "${_out}" myrepo \
    false false 0 gpu _extras mynet "" "" "" "" "" host host private >/dev/null 2>&1

  # The stage joined it ...
  run grep -cF '      - mynet' "${_out}"
  assert_output "1"
  # ... so the project declares it.
  run grep -c '^networks:$' "${_out}"
  assert_output "1"
  # ... and devel, which did not join, still has host networking.
  local _devel_block
  _devel_block="$(awk '/^  devel:/{f=1;next} /^  [a-z]/{f=0} f' "${_out}")"
  assert [ -n "$(grep -F 'network_mode:' <<< "${_devel_block}")" ]
}

# why: base#1094 item 3 -- the issue's words: "Silence is the one option
# that is not available." The precedence is now stated in the template
# beside both keys, and warned about when it applies.
@test "a network_name under a non-bridge mode is reported, naming both keys (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml"
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    mynet '' '' '' '' '' host host private 2>&1"
  assert_success
  assert_output --partial "joins a named network only under mode = bridge"
}

@test "a network_name under mode = bridge is not reported (base#1094)" {
  _write_dockerfile "${TEMP_DIR}"
  local _out="${TEMP_DIR}/compose.yaml"
  run bash -c "cd '${TEMP_DIR}' && source /source/dist/script/docker/wrapper/setup.sh && \
    _extras=() && generate_compose_yaml '${_out}' myrepo false false 0 gpu _extras \
    mynet '' '' '' '' '' bridge host private 2>&1"
  assert_success
  refute_output --partial "joins a named network only under mode = bridge"
}

@test "setting network.network_name under the shipped host default warns at store time (base#1094)" {
  local _d
  _d="$(_conf_dir '[network]
mode = "host"
')"
  run bash /source/dist/script/docker/wrapper/setup.sh set network.network_name mynet --base-path "${_d}"
  assert_success
  assert_output --partial "joins a named network only under mode = bridge"
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (4): [deploy] dri_groups cannot express a value
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 4 -- the key looked like a setting and was a
# switch: the validator took only `auto` / `off`, and the GIDs themselves
# were reachable only through the `SETUP_DETECT_DRI_GROUPS` environment
# variable -- the mechanism ADR-00000025 section 9 removed everywhere
# else ("no ambient environment variable can steer the chain"). The key
# now carries the list, with `auto` still the default and the env var
# still honoured for the auto path.
@test "dri_groups carrying an explicit GID list reaches group_add without the env var (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[dri_groups_str]}")"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" "44 104"

  SETUP_DETECT_DRI_GROUPS="" _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run grep -cE '^      - "(44|104)"$' "${TEMP_DIR}/field.yaml"
  assert_output "2"
}

@test "dri_groups = off still grants nothing (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_BASE}")"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" ""
}

# ════════════════════════════════════════════════════════════════════
# base#1094 (5): [logging] in the field-deploy bundle
# ════════════════════════════════════════════════════════════════════

# why: base#1094 item 5 -- `_emit_logging_block` was called by the dev
# emitter and never by `deploy.sh`, so a repo configuring a driver,
# max_size, max_file and compress got all four in development and none
# of them in the artifact shipped to a device. That is the one place
# where an unbounded log actually fills a disk. `local_path` stays out of
# the bundle on purpose: it is a host bind, not a Docker logging option,
# and the block has never emitted it.
@test "a configured [logging] reaches the field bundle, matching the dev compose (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[logging_global_str]}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run cat "${TEMP_DIR}/field.yaml"
  assert_success
  assert_line "    logging:"
  assert_line "      driver: json-file"
  assert_line '        max-size: "5m"'
  assert_line '        max-file: "3"'
  assert_line '        compress: "true"'
}

# why: base#1094 item 5 -- `[logging.<svc>]` is the per-service override
# layer, and the bundle's service is the deployed stage. A bundle that
# took only the global block would drop exactly the override an operator
# wrote for that stage.
@test "a [logging.<stage>] override reaches the field bundle for that stage (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[logging_per_svc_str]}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run cat "${TEMP_DIR}/field.yaml"
  assert_success
  assert_line "      driver: local"
  assert_line '        max-size: "9m"'
}

# why: base#1094 item 5 -- the shipped template sets driver / max_size /
# max_file / compress, so "configure nothing" is not "no logging
# options": it is the template's bounds. Those are the ones that matter,
# because the repo that never thought about logging is the one whose
# device disk fills. This asserts the DEFAULT reaches the bundle, not
# just an explicitly configured value.
@test "the shipped [logging] defaults reach a bundle that configures nothing (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_BASE}")"
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"
  run cat "${TEMP_DIR}/field.yaml"
  assert_success
  assert_line "    logging:"
  assert_line "      driver: json-file"
  assert_line '        max-size: "10m"'
}

# why: base#1094 item 5 -- the defect was two emitters over one config
# disagreeing, so the assertion that holds the fix is agreement, not
# presence. Both tiers are handed the same _collect_logging result and
# their `logging:` blocks are compared line for line; a future change to
# one emitter's block that the other does not get fails here.
@test "the bundle's logging block is the same block the dev compose emits (base#1094)" {
  local _d
  _d="$(_conf_dir "${_REACH_PROBE[logging_global_str]}")"
  _write_dockerfile "${_d}"
  local _g="" _p=""
  _collect_logging "${_d}" _g _p

  local _dev="${_d}/compose.yaml" _extras=()
  ( cd "${_d}" && generate_compose_yaml "${_dev}" myrepo \
      false false 0 gpu _extras "" "" "" "" "" "" host host private \
      "" "" "" "" "" "" "" "" "" "${_g}" "${_p}" ) >/dev/null 2>&1
  _reach_bundle "${_d}" "${TEMP_DIR}/field.yaml"

  # The block only: everything around it differs by design (the dev
  # compose interpolates, the bundle resolves). The block is the
  # `logging:` line plus the lines indented deeper than it, so the
  # extraction ends at the next service-level key whatever that is.
  local _dev_block _field_block
  _dev_block="$(awk '/^    logging:$/{f=1;print;next} f&&/^      /{print;next} f{exit}' "${_dev}")"
  _field_block="$(awk '/^    logging:$/{f=1;print;next} f&&/^      /{print;next} f{exit}' "${TEMP_DIR}/field.yaml")"
  [[ -n "${_dev_block}" ]] || { echo "the dev compose emitted no logging block"; false; }
  assert_equal "${_field_block}" "${_dev_block}"
}
