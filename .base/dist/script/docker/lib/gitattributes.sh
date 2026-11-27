#!/usr/bin/env bash
# lib/gitattributes.sh - Canonical line-ending block for .gitattributes + its
# sync helper.
#
# Nothing fixed a line ending in a repo that vendors base (base#2246): what
# a checkout held was decided by each machine's core.autocrlf, so a Windows
# clone on the default setting turned every shell script, Dockerfile and
# justfile into CRLF, and those are read inside Linux containers. This lib
# is the single source of the rule, sourced by init.sh (new-repo +
# existing-repo paths) and consumed indirectly by upgrade.sh through
# init.sh -- the same route lib/gitignore.sh takes.
#
# It is NOT a second user of _sync_managed_entries, and cannot be. That
# sync APPENDS, which is right for an ignore file -- every line adds to the
# set, and order is irrelevant -- and wrong for this one: in
# .gitattributes the LAST matching line decides each attribute. A
# `* text=auto eol=lf` appended below a repo's own `*.usd binary` or
# `fixture.txt -text` would win over it and convert the very files the
# repo had marked. So the block is placed ABOVE everything the repo wrote,
# where the repo's lines win, and it is delimited by an explicit BEGIN /
# END marker pair so a later release can rewrite its contents in place.

# log.sh for the malformed-block refusal, the way lib/gitignore.sh pulls it
# in: init.sh gets the logger through _lib.sh, a unit spec sourcing this
# file on its own does not. log.sh is self-guarding, so a double source is
# free.
_gitattributes_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_gitattributes_lib_dir}/log.sh"
unset _gitattributes_lib_dir

# _gitattributes_marker_begin / _gitattributes_marker_end
#   The two lines that delimit the template-owned block. Functions rather
#   than readonly globals so sourcing this file twice (init.sh, then a
#   spec) does not trip over a redeclaration.
_gitattributes_marker_begin() {
  printf '%s\n' '# managed by template: line endings begin (do not remove)'
}
_gitattributes_marker_end() {
  printf '%s\n' '# managed by template: line endings end (do not remove)'
}

# _canonical_gitattributes_block
#   Print the canonical line-ending block, markers included, exactly as it
#   stands in a synced .gitattributes.
#
#   `* text=auto eol=lf` is the rule: a file git detects as text is stored
#   with LF and checked out with LF, whatever core.autocrlf says.
#   `*.bat` / `*.cmd` are the two types that must reach a Windows shell
#   with CRLF; they are still stored with LF. The `binary` lines name
#   types `text=auto` already detects from their content -- they are
#   listed so the answer does not rest on a heuristic over the first few
#   kilobytes of a file.
#
#   base's own root .gitattributes opens with this block too, and
#   gitattributes_sync_spec holds the two to byte equality, so the rule base
#   ships is the rule base lives under.
#
#   Changing a line here changes it in every downstream on its next
#   upgrade: the sync rewrites what stands between the markers.
_canonical_gitattributes_block() {
  _gitattributes_marker_begin
  cat <<'EOF'
# Text files are LF in the repository and in every checkout, whatever the
# local core.autocrlf is. This block is template-owned and is rewritten on
# upgrade: put a repo's own rules BELOW the end marker, where they win
# (the last matching line decides).
* text=auto eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf
*.7z binary
*.bin binary
*.bmp binary
*.bz2 binary
*.deb binary
*.dll binary
*.exe binary
*.gif binary
*.gz binary
*.ico binary
*.jpeg binary
*.jpg binary
*.otf binary
*.pdf binary
*.png binary
*.so binary
*.tar binary
*.tgz binary
*.ttf binary
*.webp binary
*.whl binary
*.woff binary
*.woff2 binary
*.xz binary
*.zip binary
EOF
  _gitattributes_marker_end
}

# _gitattributes_install <tmp> <path>
#   Put the composed file <tmp> in place of <path>, unless the two already
#   hold the same bytes -- in which case nothing is written and <tmp> is
#   removed, which is what makes the sync idempotent and keeps an
#   up-to-date file's mtime, and the staging step's "did this run write
#   it" answer, honest.
#
#   <tmp> comes from a bare mktemp (0600), so <path> lends it
#   its mode first (base#1356); a chmod that fails abandons the write
#   rather than landing a 0600 file over the repo's own.
_gitattributes_install() {
  local _tmp="$1" _path="$2"
  if cmp -s -- "${_tmp}" "${_path}"; then
    rm -f -- "${_tmp}"
    return 0
  fi
  if ! chmod --reference="${_path}" -- "${_tmp}"; then
    rm -f -- "${_tmp}"
    _log_err init gitattributes_sync_failed \
      "display=could not give the rewrite the mode of ${_path}; the line-ending block was not synced and the file is unchanged" \
      "file=${_path}"
    return 1
  fi
  mv -f -- "${_tmp}" "${_path}"
}


# _gitattributes_compose <src> <bom> <begin_ln> <end_ln>
#   Print the synced file: the byte order mark when <bom> is 1, then the
#   canonical block and the repo's own content read from <src>, which never
#   holds a mark itself.
#
#   <begin_ln> 0 means <src> has no block: the block goes first, then a
#   blank line and <src> as it is. Otherwise the lines <begin_ln> through
#   <end_ln> are the block to replace, and head / tail copy what stands
#   before and after it -- they copy bytes, so a missing final newline
#   comes through exactly as it was.
#
#   Every writer is checked. The caller redirects this into a draft that
#   replaces the repo's file, and a group's exit status is only its last
#   command's: an unchecked writer that failed midway would hand over a
#   truncated draft as a success.
_gitattributes_compose() {
  local _src="$1" _bom="$2" _begin_ln="$3" _end_ln="$4"
  if (( _bom )); then
    printf '\357\273\277' || return 1
  fi
  if (( _begin_ln == 0 )); then
    _canonical_gitattributes_block || return 1
    [[ -s "${_src}" ]] || return 0
    printf '\n' || return 1
    cat -- "${_src}" || return 1
    return 0
  fi
  if (( _begin_ln > 1 )); then
    head -n "$(( _begin_ln - 1 ))" -- "${_src}" || return 1
  fi
  _canonical_gitattributes_block || return 1
  tail -n "+$(( _end_ln + 1 ))" -- "${_src}" || return 1
}

# _sync_gitattributes <path>
#   Make <path> carry the canonical line-ending block, touching nothing
#   else in it.
#
#     no file              create it holding the block alone
#     no marker            put the block at the TOP, a blank line, then
#                          the existing content byte for byte. At the top
#                          because the last matching line wins: every rule
#                          the repo already wrote stays below the block
#                          and keeps deciding the paths it names
#     one BEGIN, one END,  rewrite the lines from BEGIN through END to the
#     in that order        canonical block; everything before and after is
#                          copied byte for byte. This is the upgrade path
#                          for a block an earlier release wrote, and a
#                          no-op when the block is already current
#     anything else        a lone marker, a repeated one, or END before
#                          BEGIN is a malformed block: REFUSE, with the
#                          file byte-identical, rather than guess where
#                          the template's half stops. Guessing is how a
#                          sync deletes a rule somebody wrote
#
#   A UTF-8 byte order mark opening the file stays the file's first three
#   bytes, and the block goes after it. git skips a mark only at the very
#   start of .gitattributes; one left at the head of the repo's first line
#   becomes part of that line's pattern, and the rule stops matching -- a
#   `fixture.txt -text` silently handed to `* text=auto eol=lf`. The mark
#   is set aside before the markers are looked for, so the sync's own
#   output for such a file (mark, then BEGIN) is read back as a block.
#
#   The sync never renormalizes. It decides what a FUTURE `git add` stores
#   and what a checkout writes; a file already committed with CRLF stays
#   that way until the repo runs `git add --renormalize .` itself, in a
#   commit of its own.
#
#   Idempotent: a second run over its own output writes nothing.
_sync_gitattributes() {
  local _path="${1:?BUG: _sync_gitattributes expects a path}"
  local _begin _end
  _begin="$(_gitattributes_marker_begin)"
  _end="$(_gitattributes_marker_end)"

  if [[ ! -f "${_path}" ]]; then
    # Written straight to its name: there is no earlier content a failed
    # write could damage, and the file takes the mode the umask gives any
    # other new file in the repo.
    _canonical_gitattributes_block > "${_path}"
    return
  fi

  # Locate the markers by reading the file in-shell: no pipeline whose
  # reader can leave early, and a final line with no trailing newline is
  # still seen (`|| [[ -n ... ]]`) -- a marker could be it.
  local _line _lineno=0 _begin_ln=0 _end_ln=0 _begin_n=0 _end_n=0 _bom=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if (( _lineno == 1 )) && [[ "${_line}" == $'\357\273\277'* ]]; then
      _bom=1
      _line="${_line#$'\357\273\277'}"
    fi
    if [[ "${_line}" == "${_begin}" ]]; then
      _begin_n=$(( _begin_n + 1 ))
      _begin_ln="${_lineno}"
    elif [[ "${_line}" == "${_end}" ]]; then
      _end_n=$(( _end_n + 1 ))
      _end_ln="${_lineno}"
    fi
  done < "${_path}"

  if (( _begin_n + _end_n > 0 )) \
     && (( _begin_n != 1 || _end_n != 1 || _begin_ln > _end_ln )); then
    _log_err init gitattributes_managed_block_invalid \
      "display=${_path}: the line-ending managed block is malformed (${_begin_n} begin marker(s), ${_end_n} end marker(s); exactly one of each is expected, begin first). Restore the pair around the template's lines, or delete both markers and the lines between them, then re-run the sync. The file was NOT modified." \
      "path=${_path}" "begin_markers=${_begin_n}" "end_markers=${_end_n}"
    return 1
  fi

  # The draft, and for a file with a byte order mark a second working file
  # holding the content without it, so every line number above counts the
  # same lines in what head / tail are given.
  local _tmp _src="${_path}" _body="" _rc=0
  _tmp="$(mktemp "${_path}.XXXXXX")" || _rc=1
  if (( _rc == 0 && _bom )); then
    _body="$(mktemp "${_path}.XXXXXX")" || _rc=1
    _src="${_body}"
  fi
  if (( _rc != 0 )); then
    [[ -z "${_tmp}" ]] || rm -f -- "${_tmp}"
    _log_err init gitattributes_sync_failed \
      "display=could not create a temporary file beside ${_path}; the line-ending block was not synced and the file is unchanged" \
      "file=${_path}"
    return 1
  fi

  if (( _bom )); then
    tail -c +4 -- "${_path}" > "${_body}" || _rc=1
  fi
  if (( _rc == 0 )); then
    _gitattributes_compose "${_src}" "${_bom}" "${_begin_ln}" "${_end_ln}" \
      > "${_tmp}" || _rc=1
  fi
  [[ -z "${_body}" ]] || rm -f -- "${_body}"
  if (( _rc != 0 )); then
    rm -f -- "${_tmp}"
    _log_err init gitattributes_sync_failed \
      "display=could not write the rewrite of ${_path}; the line-ending block was not synced and the file is unchanged" \
      "file=${_path}"
    return 1
  fi
  _gitattributes_install "${_tmp}" "${_path}"
}
