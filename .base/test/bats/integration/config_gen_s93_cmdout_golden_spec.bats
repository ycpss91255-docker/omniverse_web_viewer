#!/usr/bin/env bats
#
# config_gen_s93_cmdout_golden_spec.bats -- the s93 corpus of host command
# output against what today's shell makes of it (base#2068, S93a of
# base#1829 under base#1395).
#
# why: Before any Go code reads `docker info` or `dpkg-query` output, the
# shell's reading of it is pinned. Each corpus file under
# dockerfile/config-gen/testdata/corpus/s93 is the text a stubbed `docker`
# (s93_docker_*) or `dpkg-query` (s93_dpkg_*) prints; the golden under
# testdata/golden/s93/<stem>.golden is the one line `detect_docker_hub_user`
# / `detect_gpu` (dist/script/docker/lib/setup_detect.sh) leaves in its
# outvar, followed by a newline. The spec regenerates every golden from the
# shell and fails on any byte difference, on a corpus file with no golden,
# and on a golden with no corpus file.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  TESTDATA="/source/dockerfile/config-gen/testdata"
  CORPUS="${TESTDATA}/corpus/s93"
  GOLDEN="${TESTDATA}/golden/s93"
}

# _shell_result <stem> -- print what the shell function leaves in its outvar
# for the corpus file <stem>.txt, then a newline. USER is envuser.
_shell_result() {
  local _stem="${1}"
  CORPUS_FILE="${CORPUS}/${_stem}.txt" STEM="${_stem}" USER=envuser \
    bash -c '
      source /source/dist/script/docker/lib/setup_detect.sh
      docker() { cat -- "${CORPUS_FILE}"; }
      dpkg-query() { cat -- "${CORPUS_FILE}"; }
      nvidia-smi() { cat -- "${CORPUS_FILE}"; }
      case "${STEM}" in
        s93_docker_*) detect_docker_hub_user _out ;;
        s93_dpkg_*)   detect_gpu _out ;;
        s93_gpu_*)    detect_gpu_count _out ;;
        *) printf "unknown stem: %s\n" "${STEM}" >&2; exit 2 ;;
      esac
      printf "%s\n" "${_out}"
    '
}

# _env_result <stem> -- print what the shell makes of the display variables
# in <stem>.env (DISPLAY=, WAYLAND_DISPLAY=, SSH_CONNECTION=): "gui=<true|false>"
# from detect_gui, then "ssh_x11=<0|1>" (the return code of _is_ssh_x11),
# each followed by a newline (base#2075).
_env_result() {
  local _stem="${1}" _line
  local _d="" _w="" _s=""
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    case "${_line}" in
      DISPLAY=*)         _d="${_line#DISPLAY=}" ;;
      WAYLAND_DISPLAY=*) _w="${_line#WAYLAND_DISPLAY=}" ;;
      SSH_CONNECTION=*)  _s="${_line#SSH_CONNECTION=}" ;;
    esac
  done < "${CORPUS}/${_stem}.env"
  DISPLAY="${_d}" WAYLAND_DISPLAY="${_w}" SSH_CONNECTION="${_s}" \
    bash -c '
      source /source/dist/script/docker/lib/setup_detect.sh
      detect_gui _gui
      printf "gui=%s\n" "${_gui}"
      _is_ssh_x11
      printf "ssh_x11=%d\n" "$?"
    '
}

# _check_prefix <stem-prefix> [ext] -- every corpus file with the prefix has a
# golden and the shell result matches it byte for byte. ext is txt (default,
# command output, _shell_result) or env (display variables, _env_result).
# Prints one line per violation; returns 1 on any.
_check_prefix() {
  local _prefix="${1}" _ext="${2:-txt}" _f _stem _bad=0 _fn=_shell_result
  [[ "${_ext}" == env ]] && _fn=_env_result
  for _f in "${CORPUS}/${_prefix}"*."${_ext}"; do
    [[ -e "${_f}" ]] || continue
    _stem="$(basename -- "${_f}" ".${_ext}")"
    if [[ ! -f "${GOLDEN}/${_stem}.golden" ]]; then
      printf 'corpus with no golden: %s\n' "${_stem}"
      _bad=1
      continue
    fi
    "${_fn}" "${_stem}" > "${BATS_TEST_TMPDIR}/got"
    if ! cmp -s -- "${BATS_TEST_TMPDIR}/got" "${GOLDEN}/${_stem}.golden"; then
      printf 'golden differs: %s\n' "${_stem}"
      _bad=1
    fi
  done
  return "${_bad}"
}

# why: the issue names nine corpus files; a missing one would silently
# shrink what is pinned.
@test "s93: the nine named corpus files exist" {
  local _s
  for _s in s93_docker_user_logged_in s93_docker_user_absent \
            s93_docker_user_empty_value s93_docker_user_extra_word \
            s93_dpkg_ii s93_dpkg_rc s93_dpkg_un s93_dpkg_empty \
            s93_dpkg_ii_then_rc; do
    [[ -f "${CORPUS}/${_s}.txt" ]] || { echo "missing corpus: ${_s}"; return 1; }
  done
}

# why: detect_docker_hub_user reads the second field of the Username line and
# falls back to USER when the line or the value is absent.
@test "s93: detect_docker_hub_user result matches every golden" {
  run _check_prefix s93_docker_
  [ "${status}" -eq 0 ] || { printf '%s\n' "${output}"; return 1; }
}

# why: detect_gpu is true only when some status line starts with ii.
@test "s93: detect_gpu result matches every golden" {
  run _check_prefix s93_dpkg_
  [ "${status}" -eq 0 ] || { printf '%s\n' "${output}"; return 1; }
}

# why: base#2072 (S93b) names four nvidia-smi -L corpus files; a missing one
# would silently shrink what is pinned.
@test "s93: the four named nvidia-smi corpus files exist" {
  local _s
  for _s in s93_gpu_two s93_gpu_mig_lines s93_gpu_empty s93_gpu_no_devices; do
    [[ -f "${CORPUS}/${_s}.txt" ]] || { echo "missing corpus: ${_s}"; return 1; }
  done
}

# why: detect_gpu_count counts only lines starting with "GPU "; indented MIG
# lines and "No devices were found" do not count.
@test "s93: detect_gpu_count result matches every golden" {
  run _check_prefix s93_gpu_
  [ "${status}" -eq 0 ] || { printf '%s\n' "${output}"; return 1; }
}

# why: the worked counts come from the issue, not from the shell.
@test "s93: the four gpu goldens hold the issue's counts" {
  local _pair _stem _want
  for _pair in s93_gpu_two:2 s93_gpu_mig_lines:1 s93_gpu_empty:0 \
               s93_gpu_no_devices:0; do
    _stem="${_pair%%:*}"; _want="${_pair##*:}"
    [[ -f "${GOLDEN}/${_stem}.golden" ]] || { echo "missing golden: ${_stem}"; return 1; }
    [ "$(cat -- "${GOLDEN}/${_stem}.golden")" = "${_want}" ] || { echo "wrong golden: ${_stem}"; return 1; }
  done
}

# why: base#2075 (S93c) names seven display-variable corpus files; a missing
# one would silently shrink what is pinned.
@test "s93: the seven named env corpus files exist" {
  local _s
  for _s in s93_env_none s93_env_x11_local s93_env_wayland s93_env_ssh_x11 \
            s93_env_ssh_x11_no_screen s93_env_ssh_local_display \
            s93_env_ssh_bad_display; do
    [[ -f "${CORPUS}/${_s}.env" ]] || { echo "missing corpus: ${_s}"; return 1; }
  done
}

# why: detect_gui and _is_ssh_x11 read DISPLAY, WAYLAND_DISPLAY and
# SSH_CONNECTION; the shell result must match every golden byte for byte.
@test "s93: detect_gui and _is_ssh_x11 results match every golden" {
  run _check_prefix s93_env_ env
  [ "${status}" -eq 0 ] || { printf '%s\n' "${output}"; return 1; }
}

# why: the worked results come from the issue, not from the shell.
@test "s93: the seven env goldens hold the issue's results" {
  local _pair _stem _want
  for _pair in s93_env_none:false:1 s93_env_x11_local:true:1 \
               s93_env_wayland:true:1 s93_env_ssh_x11:true:0 \
               s93_env_ssh_x11_no_screen:true:1 \
               s93_env_ssh_local_display:true:1 \
               s93_env_ssh_bad_display:true:1; do
    _stem="${_pair%%:*}"; _want="gui=$(cut -d: -f2 <<<"${_pair}")"$'\n'"ssh_x11=${_pair##*:}"
    [[ -f "${GOLDEN}/${_stem}.golden" ]] || { echo "missing golden: ${_stem}"; return 1; }
    [ "$(cat -- "${GOLDEN}/${_stem}.golden")" = "${_want}" ] || { echo "wrong golden: ${_stem}"; return 1; }
  done
}

# why: a golden whose corpus file was deleted would stand for nothing.
@test "s93: every golden has a corpus file" {
  local _g _stem _bad=0
  for _g in "${GOLDEN}"/*.golden; do
    [[ -e "${_g}" ]] || continue
    _stem="$(basename -- "${_g}" .golden)"
    if [[ ! -f "${CORPUS}/${_stem}.txt" && ! -f "${CORPUS}/${_stem}.env" ]]; then
      printf 'golden with no corpus: %s\n' "${_stem}"
      _bad=1
    fi
  done
  [ "${_bad}" -eq 0 ]
}
