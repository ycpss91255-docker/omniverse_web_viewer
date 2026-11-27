#!/usr/bin/env bash
# drivers/tracked_crlf.sh - "no tracked text file is stored with CRLF line
# endings" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_tracked_crlf. Follows drivers/canonical_ignore_sync.sh /
# drivers/stale_setup_conf.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# Contract: runs wherever test.sh invokes it -- the ci (test-tools)
# container or a plain runner. References ${REPO_ROOT} (a global exported by
# test.sh), which must be a git work tree: the question is asked of the
# INDEX, and a tree with no index has no answer.
#
# ── What it refuses, and why ────────────────────────────────────────────────
#
# base#2246. Nothing in this repo fixed a line ending. The root
# .gitattributes carried `merge=union` for the changelog and `-text` for a
# few byte-exact fixtures and no `text` / `eol` rule, so what a checkout
# held was decided by each machine's core.autocrlf. A Windows clone on the
# default setting turned every shell script, Dockerfile, bats spec and
# justfile into CRLF, and those are read inside Linux containers:
# `\r: command not found`, and a shebang naming an interpreter that ends in
# a carriage return.
#
# The root .gitattributes now opens with `* text=auto eol=lf`. That rule
# governs the CHECKOUT side, and it normalises on `git add` -- but under
# `text=auto` git leaves a file alone when the copy already in the index
# holds a CR, so a CRLF file committed before the rule (or on a branch
# that predates it) stays CRLF in the repository until somebody runs
# `git add --renormalize`. Nothing reports that state: the file checks out
# exactly as it was committed and every tool reads it happily until the
# one that does not.
#
# ── The rule ────────────────────────────────────────────────────────────────
#
# Read `git ls-files --eol` and refuse every tracked path whose INDEX side
# is `i/crlf` or `i/mixed`, unless its attributes carry `-text`.
#
# The index side, not the working tree. The working tree is what
# core.autocrlf and the `eol` attribute rewrite, so it differs between a
# Windows clone and a CI runner; the index is the same bytes everywhere,
# which is what makes one verdict hold on both.
#
# `-text` is the whole exemption, and it is the one git itself uses: a path
# marked `-text` (directly, or through the `binary` macro) is never
# converted, so CRLF in it is content. That is how this repo already marks
# its deliberate CRLF fixtures (base#1463, base#1469, base#1442), and a new
# one opts out the same way -- in .gitattributes, where the checkout rule
# reads it too, rather than in an allow-list here that the checkout would
# know nothing about.
#
# `eol=crlf` is deliberately NOT an exemption. A path carrying it (`*.bat`,
# `*.cmd`) is still a text file: git stores it with LF and writes CRLF on
# checkout, so its index side reads `i/lf` and passes. One that reads
# `i/crlf` was committed before the attribute applied and needs the same
# renormalize as any other.
#
# A file git detects as binary reads `i/-text` and is not a finding; an
# empty one reads `i/none`. Neither holds a line ending to get wrong.
#
# ── What makes a clean run mean something ───────────────────────────────────
#
# git refusing to answer (not a work tree, an unreadable index) and a tree
# with NO tracked file both die rather than pass. Each is a way for the
# loop below to visit nothing, and a lint that visited nothing reports the
# same "clean" as one that found nothing.
#
# ONE state is reported as NOT RUN rather than refused: a `git worktree`
# checkout seen from inside the ci container. Its `.git` is a file naming
# a gitdir outside the bind mount, so no in-container git command can read
# the index at all (test.sh records the same limit for the shell-metric
# lints and for the previous-release tags). Dying there would fail the
# whole local lint phase for every worktree, over a question the container
# cannot ask. So the driver says, in so many words, that it examined
# nothing and names the host arm that can. A CI checkout's `.git` is a
# directory, so that branch is unreachable on a runner, which is where
# this lint gates.

# _tracked_crlf_gitdir_unreachable
#   Succeed when ${REPO_ROOT}/.git is a worktree pointer FILE whose gitdir
#   is not a directory this process can see. Fail for a `.git` directory,
#   for no `.git` at all and for a pointer that resolves -- every one of
#   which git itself must answer for.
_tracked_crlf_gitdir_unreachable() {
  local _dotgit="${REPO_ROOT}/.git" _line="" _target
  [[ -f "${_dotgit}" ]] || return 1
  IFS= read -r _line < "${_dotgit}" || [[ -n "${_line}" ]] || return 1
  [[ "${_line}" == "gitdir: "* ]] || return 1
  _target="${_line#gitdir: }"
  [[ "${_target}" == /* ]] || _target="${REPO_ROOT}/${_target}"
  [[ ! -d "${_target}" ]]
}

# _tracked_crlf_listing <out_file>
#   Write `git ls-files --eol -z` for ${REPO_ROOT} to <out_file> and return
#   git's own status. `-z` because a path with a tab, a quote or a
#   non-ASCII byte is C-quoted without it, and the report has to name the
#   path a reader can pass straight back to git.
#
#   safe.directory is set on the command line because the ci container
#   mounts the checkout from a host user it does not run as, and git
#   refuses such a tree outright ("dubious ownership") -- which would turn
#   every run there into the not-a-work-tree refusal below. The lint reads
#   the index and runs nothing from the tree, so the guard has nothing to
#   protect here.
_tracked_crlf_listing() {
  local _out="${1:?BUG: _tracked_crlf_listing expects an output file}"
  git -c "safe.directory=*" -C "${REPO_ROOT}" ls-files --eol -z > "${_out}"
}

_run_tracked_crlf() {
  echo "--- Running tracked CRLF lint ---"

  if _tracked_crlf_gitdir_unreachable; then
    echo "tracked CRLF lint: NOT RUN -- ${REPO_ROOT}/.git names a worktree" \
         "gitdir this process cannot see (the checkout is bind-mounted" \
         "without it), so the index could not be read and NO file was" \
         "examined. Run './script/test/test.sh --tracked-crlf-only' on" \
         "the host for the real answer."
    return 0
  fi

  local _listing
  _listing="$(mktemp)" || {
    _die ci_tracked_crlf \
      "could not create a temporary file for the 'git ls-files --eol' listing, so no tracked path was examined."
    return 1
  }

  if ! _tracked_crlf_listing "${_listing}"; then
    rm -f -- "${_listing}"
    _die ci_tracked_crlf \
      "'git ls-files --eol' failed under ${REPO_ROOT} -- git's own message is above. The lint reads line endings from the index, so a tree that is not a git work tree (or whose index cannot be read) has nothing to examine, and passing here would be passing vacuously."
    return 1
  fi

  # One record per tracked path:
  #   i/<eol> w/<eol> attr/<attributes><TAB><path><NUL>
  # The fields before the tab are padded with spaces and the attribute
  # field itself holds spaces (`text=auto eol=lf`), so the record is cut at
  # the FIRST tab -- a path may contain later ones -- and the attribute
  # field is whatever follows `attr/`.
  local -a _offenders=()
  local _rec _meta _path _index _attr _total=0
  while IFS= read -r -d '' _rec; do
    _total=$(( _total + 1 ))
    _meta="${_rec%%$'\t'*}"
    _path="${_rec#*$'\t'}"
    _index="${_meta%% *}"
    [[ "${_index}" == "i/crlf" || "${_index}" == "i/mixed" ]] || continue
    _attr="${_meta#*attr/}"
    # Padded both sides so `-text` is matched as a whole word.
    [[ " ${_attr} " == *" -text "* ]] && continue
    _offenders+=("${_index#i/}"$'\t'"${_path}")
  done < "${_listing}"
  rm -f -- "${_listing}"

  if (( _total == 0 )); then
    _die ci_tracked_crlf \
      "'git ls-files --eol' listed no tracked file under ${REPO_ROOT}, so there was nothing to examine and the lint would pass vacuously. Point it at the repository checkout."
    return 1
  fi

  if (( ${#_offenders[@]} > 0 )); then
    # One printf per offender, for the reason canonical_ignore_sync.sh
    # records: a format reused across an array pairs its arguments wrongly.
    local _off
    for _off in "${_offenders[@]}"; do
      printf '%s: stored with %s line endings\n' \
        "${_off#*$'\t'}" "${_off%%$'\t'*}"
    done
    _die ci_tracked_crlf \
      "${#_offenders[@]} of ${_total} tracked files hold CRLF line endings in the index. Each line above names one. A text file is stored with LF here (root .gitattributes: '* text=auto eol=lf'); fix one with 'git add --renormalize -- <path>' and commit that on its own. If the carriage returns ARE the content -- a byte-exact fixture -- mark the path '-text' in .gitattributes instead, which is the only exemption: 'eol=crlf' is not one, because such a file is still stored with LF and only checked out with CRLF."
    return 1
  fi

  echo "tracked CRLF lint: clean" \
       "(${_total} tracked files, none stored with CRLF outside a" \
       "'-text' path)"
}
