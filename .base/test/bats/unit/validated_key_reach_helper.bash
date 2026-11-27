#!/usr/bin/env bash
#
# Shared setup()/teardown() and fixtures for validated_key_reach_spec.bats
# and validated_key_explicit_spec.bats: the conf directories, the baseline,
# the per-field probe table and the bundle writer both files read.

setup() {
  export LOG_FORMAT=text
  export SETUP_LANG=en
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
  TEMP_DIR="$(mktemp -d)"
  # Use the in-container bridge directly instead of `docker run` (mirrors
  # compose_emit/gen_spec.bats).
  toml_bridge_parse() {
    local _file="${1:?missing file}"
    shift
    [[ -f "${_file}" ]] || { echo "toml_bridge_parse: file not found: ${_file}" >&2; return 1; }
    /usr/local/bin/toml-bridge "$@" < "${_file}"
  }
  toml_bridge_merge() {
    local _kv_flag=""
    if [[ "${1:-}" == "--kv" ]]; then _kv_flag="--kv"; shift; fi
    local -a _args=("--merge")
    [[ -n "${_kv_flag}" ]] && _args+=("--kv")
    _args+=("$@")
    /usr/local/bin/toml-bridge "${_args[@]}"
  }
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# A conf directory holding exactly the text given. The WHOLE file, not a
# fragment appended to a baseline: a TOML table may not be opened twice,
# and a duplicate table makes the bridge refuse the file -- which, from
# the outside, looks exactly like "setting this key changed nothing".
# That confusion is what base#1164 was about, and a probe harness is the
# easiest place to reintroduce it.
_conf_dir() {
  local _d
  _d="$(mktemp -d --tmpdir="${TEMP_DIR}")"
  printf '%s' "${1}" > "${_d}/setup.toml"
  printf '%s' "${_d}"
}

# A minimal Dockerfile the dev emitter's per-stage loop needs.
_write_dockerfile() {
  cat > "${1}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
}

# The deterministic baseline every probe is a one-key edit of: headless,
# no GPU, no /dev/dri grant, host networking. Everything it emits is a
# literal, so a difference in the generated file is the probe's doing.
_REACH_BASE='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'

# One probe per field of the deploy context: the WHOLE conf, with that
# field moved off its baseline value (and nothing else moved except what
# the field needs to be live at all -- `shm_size` needs a non-host `ipc`,
# `ports` needs bridge). Completeness is DERIVED below against the
# context record's own key set, so a field added to the resolver without
# a probe is a red test rather than a silent hole in this gate.
declare -gA _REACH_PROBE=(
  [build_network]='[build]
network = "host"
[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_mode]='[deploy]
gpu_mode = "force"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_count]='[deploy]
gpu_mode = "force"
gpu_count = 3
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_caps]='[deploy]
gpu_mode = "force"
gpu_capabilities = "gpu compute"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gpu_runtime_mode]='[deploy]
gpu_mode = "off"
gpu_runtime = "nvidia"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
'
  [gui_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "force"
[network]
mode = "host"
'
  [dri_groups_str]='[deploy]
gpu_mode = "off"
dri_groups = "44 104"
[gui]
mode = "force"
[network]
mode = "host"
'
  [net_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "bridge"
network_name = "probenet"
'
  [network_name]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "bridge"
network_name = "probenet"
'
  [ipc_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
ipc = "shareable"
'
  [pid_mode]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
pid = "container:probe0"
'
  [privileged]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[security]
privileged = true
'
  [restart_policy]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[lifecycle]
# tool-pin: ignore -- a compose restart policy, not a third-party version
restart = "on-failure:5"
'
  [init]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[lifecycle]
init = false
'
  [watchdog_env_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[lifecycle]
watchdog_check = "probe-cmd"
'
  [devices_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[devices.bindings]]
path = "/dev/probe0:/dev/probe0"
'
  [cgroup_rule_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[devices.cgroup_rules]]
rule = "c 81:* rmw"
'
  [env_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[environment]
env_1 = "PROBE0=1"
'
  [tmpfs_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[tmpfs]]
path = "/probe0"
'
  [ports_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "bridge"
network_name = "probenet"
[[network.ports]]
host = 18080
container = 80
'
  [cap_add_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[security.cap_add]]
cap = "SYS_NICE"
'
  [cap_drop_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[security.cap_drop]]
cap = "NET_RAW"
'
  [sec_opt_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[[security.security_opt]]
opt = "seccomp:unconfined"
'
  [shm_size]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
ipc = "shareable"
[resources]
shm_size = "2g"
'
  [logging_global_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[logging]
driver = "json-file"
max_size = "5m"
max_file = 3
compress = true
'
  [logging_per_svc_str]='[deploy]
gpu_mode = "off"
dri_groups = "off"
[gui]
mode = "off"
[network]
mode = "host"
[logging.runtime]
driver = "local"
max_size = "9m"
'
)

# Write the bundle compose for <conf_dir> into <out_file>.
_reach_bundle() {
  local _conf="${1}" _out="${2}"
  local -A _binds=() _ctx=()
  _resolve_deploy_context "${_conf}" _ctx
  _generate_resolved_compose "${_conf}" runtime img name "${_out}" _binds _ctx
}
