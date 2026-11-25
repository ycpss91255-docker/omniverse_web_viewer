#!/usr/bin/env bash
#
# check_selection.sh -- which classify-gated self-test jobs a change can
# affect, base#1584.
#
# Usage:
#   check_selection.sh --event <event> --paths      # NUL-separated paths on stdin
#   check_selection.sh --event <event> --base <ref> # paths from git diff <ref>...HEAD
#   check_selection.sh --jobs                       # the gated job names alone
#
# Prints one `<job>=<true|false>` line per gated job, in a fixed order.
#
# CI and `test.sh --selection` never run this file from the working tree:
# script/ci/selection_at_base.sh runs the BASE side's copy, so a pull
# request that edits the map is judged by the map as it was before the
# edit. The map reads no file but the deny list beside it
# (config_gen_paths.sh), so the base copy runs from any directory.
#
# The selection is the union over every changed path, and every job starts
# unselected. A path takes the first row that matches it:
#   1. docs (Markdown under doc/, README.md, LICENSE, CONTEXT.md): nothing.
#      Narrower than classify's code_changed, which takes all of doc/: any
#      other file there (a script, an image, a justfile) is row 5. With
#      --base the file must also be a plain file on every side of the diff
#      that has it, so a symlink, an executable or a submodule is row 5
#      (base#2110).
#   2. any justfile: every job.
#   3. an exact config_gen_paths.sh entry: every job but config-gen.
#   4. a unit or integration `*_spec.bats` leaf: coverage and the code
#      checks; a system `*_spec.bats` leaf also selects system.
#   5. anything else: every job. A new, renamed or moved file, a symlink,
#      a reader tree and the selection's own files all land here.
#
# Fail closed: input this file cannot read as a list of changed paths
# prints every job `true`, exits 0, and names the reason on stderr as
# `check_selection_select_all reason=<r>`.

set -euo pipefail
# [[:cntrl:]] below must mean the C control bytes, whatever the caller's
# locale.
export LC_ALL=C

# The gated jobs, in output order. coverage-gate prints coverage's value,
# worker-selftest prints system's, and shellcheck, hadolint, bats-fragile,
# mutation-roster and test-tools-image-arm64 print the code value (false
# only for docs, base#2110).
readonly -a _CS_JOBS=(config-gen coverage coverage-gate acceptance system
  worker-selftest shellcheck hadolint bats-fragile mutation-roster
  test-tools-image-arm64)
# The answers the rows set; every job above prints one of them.
readonly -a _CS_KEYS=(config-gen coverage acceptance system code)

_cs_usage() {
  printf 'usage: %s --event <event> (--base <ref> | --paths) | --jobs\n' "${0##*/}" >&2
}

# _cs_key <job> -- the row answer <job> prints.
_cs_key() {
  case "$1" in
    coverage-gate) echo coverage ;;
    worker-selftest) echo system ;;
    shellcheck | hadolint | bats-fragile) echo code ;;
    mutation-roster | test-tools-image-arm64) echo code ;;
    *) echo "$1" ;;
  esac
}

# _cs_select_all <reason>
#   Prints every gated job as selected and names <reason> on stderr: the
#   answer for a run that is not a pull request, and for any input the
#   map could not read (fail closed).
_cs_select_all() {
  local _job
  printf 'check_selection_select_all reason=%s\n' "$1" >&2
  for _job in "${_CS_JOBS[@]}"; do printf '%s=true\n' "${_job}"; done
}

# _cs_select <key>... -- marks each row answer selected in the caller's _sel.
_cs_select() {
  local _k
  for _k in "$@"; do _sel["${_k}"]=true; done
}

# _cs_classify <path> [<old-mode> <new-mode>] -- applies the first row that
#   matches <path>. A mode is git's, 000000 for a side without the file;
#   with none given the path alone decides.
_cs_classify() {
  local _mode _plain=1
  for _mode in "${@:2}"; do
    [[ "${_mode}" == 100644 || "${_mode}" == 000000 ]] || _plain=0
  done
  case "${_plain}$1" in
    1doc/*.md | 1README.md | 1LICENSE | 1CONTEXT.md) return 0 ;;
  esac
  case "$1" in
    justfile* | */justfile*) _cs_select "${_CS_KEYS[@]}"; return 0 ;;
  esac
  if [[ -n "${_deny[$1]:-}" ]]; then
    _cs_select coverage acceptance system code
    return 0
  fi
  case "$1" in
    test/bats/unit/*_spec.bats | test/bats/integration/*_spec.bats)
      _cs_select coverage code
      ;;
    test/bats/system/*_spec.bats)
      _cs_select coverage code system
      ;;
    *) _cs_select "${_CS_KEYS[@]}" ;;
  esac
}

# _cs_load_deny -- reads config_gen_paths.sh beside this file into the
#   caller's _deny map; fails when it exits non-zero or prints nothing.
_cs_load_deny() {
  local _list _p
  _list="$(bash "$(dirname "${BASH_SOURCE[0]:-$0}")/config_gen_paths.sh")" || return 1
  [[ -n "${_list}" ]] || return 1
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] && _deny["${_p}"]=1
  done <<<"${_list}"
  return 0
}

# _cs_diff <base> <file> -- writes the PR's diff to <file> in git's
#   `--raw -z` form (a `:<modes>...` record, then the path's record), or
#   prints the fail-closed reason and fails. An empty <base> is refused by
#   name: `git diff "...HEAD"` exits 0 with no output, reading the empty
#   side as HEAD.
_cs_diff() {
  local _base="$1" _out="$2"
  [[ -n "${_base}" ]] || { echo empty_base; return 1; }
  git rev-parse --verify --quiet "${_base}^{commit}" >/dev/null 2>&1 \
    || { echo bad_base; return 1; }
  local _mb
  _mb="$(git merge-base --all "${_base}" HEAD 2>/dev/null)" || { echo no_merge_base; return 1; }
  # A three-dot diff reads one merge base of several, and can hide what the
  # others would show (base#2110).
  [[ "${_mb}" != *$'\n'* ]] || { echo many_merge_bases; return 1; }
  git diff --raw --ignore-submodules=none -z --no-renames --no-abbrev "${_base}...HEAD" >"${_out}" 2>/dev/null \
    || { echo diff_failed; return 1; }
}

# _cs_read_raw -- classifies every `--raw -z` pair on stdin with its modes,
#   or prints the fail-closed reason and fails. A pair git would not print
#   under --no-renames is unreadable.
_cs_read_raw() {
  local _meta _path _n=0
  while IFS= read -r -d '' _meta; do
    [[ "${_meta}" =~ ^:([0-7]{6})\ ([0-7]{6})\ [0-9a-f]+\ [0-9a-f]+\ [ADMT]$ ]] \
      || { echo bad_record; return 1; }
    local _old="${BASH_REMATCH[1]}" _new="${BASH_REMATCH[2]}"
    IFS= read -r -d '' _path && [[ -n "${_path}" && "${_path}" != *[[:cntrl:]]* ]] \
      || { echo bad_record; return 1; }
    _n=$((_n + 1))
    _cs_classify "${_path}" "${_old}" "${_new}"
  done
  [[ -z "${_meta}" ]] || { echo bad_record; return 1; }
  [[ "${_n}" -gt 0 ]] || { echo no_paths; return 1; }
}

# _cs_read_paths -- classifies every NUL-separated record on stdin, or
#   prints the fail-closed reason and fails. A final record with no NUL is
#   still a record. A record holding a control byte (LF and TAB included)
#   is not one path git printed under -z, so the input is unreadable:
#   `doc/a.md<LF>script/x.sh` would otherwise match the doc row as one
#   path. Zero records is no diff the map has read.
_cs_read_paths() {
  local _path _n=0
  while IFS= read -r -d '' _path || [[ -n "${_path}" ]]; do
    _n=$((_n + 1))
    [[ "${_path}" != *[[:cntrl:]]* ]] || { echo bad_record; return 1; }
    _cs_classify "${_path}"
  done
  [[ "${_n}" -gt 0 ]] || { echo no_paths; return 1; }
}

main() {
  local _event="" _from_stdin=0 _have_base=0 _base=""
  while (($# > 0)); do
    case "$1" in
      --jobs) printf '%s\n' "${_CS_JOBS[@]}"; return 0 ;;
      --event | --base)
        (($# >= 2)) || { _cs_usage; return 2; }
        if [[ "$1" == --event ]]; then _event="$2"; else _have_base=1; _base="$2"; fi
        shift 2
        ;;
      --paths) _from_stdin=1; shift ;;
      *) _cs_usage; return 2 ;;
    esac
  done
  [[ -n "${_event}" ]] || { _cs_usage; return 2; }
  [[ "${_from_stdin}" -eq 1 || "${_have_base}" -eq 1 ]] || { _cs_usage; return 2; }

  # Only a pull request narrows the selection: push, tag and
  # workflow_dispatch runs select every job, so main runs the full suite
  # (owner decision, base#1584). classify names a pull request from a fork,
  # or into any branch but the default one, by another event, so neither is
  # narrowed (base#2110).
  if [[ "${_event}" != pull_request ]]; then
    _cs_select_all non_pr
    return 0
  fi
  local _why _read=_cs_read_paths
  if [[ "${_from_stdin}" -eq 0 ]]; then
    _read=_cs_read_raw
    local _diff
    _diff="$(mktemp)"
    if ! _why="$(_cs_diff "${_base}" "${_diff}")"; then
      rm -f "${_diff}"
      _cs_select_all "${_why}"
      return 0
    fi
    exec 0<"${_diff}"
    rm -f "${_diff}"
  fi
  local -A _deny=() _sel=()
  _cs_load_deny || { _cs_select_all deny_list_unreadable; return 0; }
  local _k _job
  for _k in "${_CS_KEYS[@]}"; do _sel["${_k}"]=false; done
  # Not a command substitution: the rows write _sel in this shell.
  local _rc=0 _whyf
  _whyf="$(mktemp)"
  "${_read}" >"${_whyf}" || _rc=$?
  _why="$(cat "${_whyf}")"
  rm -f "${_whyf}"
  [[ "${_rc}" -eq 0 ]] || { _cs_select_all "${_why}"; return 0; }

  for _job in "${_CS_JOBS[@]}"; do
    printf '%s=%s\n' "${_job}" "${_sel[$(_cs_key "${_job}")]}"
  done
}

main "$@"
