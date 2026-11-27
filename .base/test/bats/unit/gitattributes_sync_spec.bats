#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/lib/gitattributes.sh -- the canonical
# line-ending block and the sync that puts it into a repo's .gitattributes.
#
# why: Unit tests for `dist/script/docker/lib/gitattributes.sh`
# (`_canonical_gitattributes_block`, `_sync_gitattributes`, refs
# base#2246). A repo that vendors base had no line-ending rule, so a
# Windows clone on the default `core.autocrlf` checked scripts out with
# CRLF. The sync installs `* text=auto eol=lf` as a marker-delimited block
# at the TOP of `.gitattributes`: the last matching line decides an
# attribute there, so a block appended below a repo's own `binary` /
# `-text` / `eol=crlf` lines would override them. The cases pin each state
# the sync can meet -- no file, no marker, a current block, a stale block,
# a malformed block -- and ask git itself (`git check-attr`) which rule
# wins.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitattributes.sh

  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1

  SCRATCH="$(mktemp -d)"
  ATTRS="${SCRATCH}/.gitattributes"
}

teardown() {
  if [[ -n "${SCRATCH:-}" ]]; then
    rm -rf "${SCRATCH}"
  fi
}

# _attr <attribute> <path> -- the value git resolves for <attribute> on
# <path> under the fixture's .gitattributes (`set`, `unset`, `unspecified`
# or the value itself).
_attr() {
  git -C "${SCRATCH}" check-attr "${1}" -- "${2}" | sed 's/.*: //'
}

# _repo -- make the fixture a git work tree, for the cases that ask git
# which rule wins.
_repo() {
  git -C "${SCRATCH}" init -q
}

# ── The block ──────────────────────────────────────────────────────────────

# why: The rule itself -- text is LF everywhere
@test "_canonical_gitattributes_block: carries the LF rule for every text file (base#2246)" {
  run _canonical_gitattributes_block
  assert_success
  assert_line '* text=auto eol=lf'
}

# why: The two script types a Windows shell needs with CRLF stay CRLF on
# checkout
@test "_canonical_gitattributes_block: keeps *.bat and *.cmd CRLF on checkout (base#2246)" {
  run _canonical_gitattributes_block
  assert_success
  assert_line '*.bat text eol=crlf'
  assert_line '*.cmd text eol=crlf'
}

# why: The sync finds its block by these two lines; a block that does not
# open and close with them cannot be rewritten later
@test "_canonical_gitattributes_block: opens with the begin marker and closes with the end marker (base#2246)" {
  run _canonical_gitattributes_block
  assert_success
  [ "${lines[0]}" = "$(_gitattributes_marker_begin)" ]
  [ "${lines[$(( ${#lines[@]} - 1 ))]}" = "$(_gitattributes_marker_end)" ]
}

# why: A marker repeated inside the block would make the sync's own output
# malformed on the next run
@test "_canonical_gitattributes_block: names each marker exactly once (base#2246)" {
  _canonical_gitattributes_block > "${SCRATCH}/block"
  [ "$(grep -cxF -- "$(_gitattributes_marker_begin)" "${SCRATCH}/block")" -eq 1 ]
  [ "$(grep -cxF -- "$(_gitattributes_marker_end)" "${SCRATCH}/block")" -eq 1 ]
}

# why: base ships this rule and must live under it -- the block at the top of
# base's own root file is the emitter's output, byte for byte
@test "_canonical_gitattributes_block: base's own root .gitattributes opens with it byte for byte (base#2246)" {
  local _own="/source/.gitattributes"
  assert_spec_subject "${_own}" "base's own attributes file, which must open with the block base ships"
  _canonical_gitattributes_block > "${SCRATCH}/block"
  local _n
  _n="$(wc -l < "${SCRATCH}/block")"
  head -n "${_n}" -- "${_own}" > "${SCRATCH}/own_head"
  run cmp -- "${SCRATCH}/block" "${SCRATCH}/own_head"
  assert_success
}

# ── No file ────────────────────────────────────────────────────────────────

# why: A new repo gets the rule without anyone writing it
@test "_sync_gitattributes: creates the file holding exactly the block when none exists (base#2246)" {
  run _sync_gitattributes "${ATTRS}"
  assert_success
  _canonical_gitattributes_block > "${SCRATCH}/block"
  run cmp -- "${SCRATCH}/block" "${ATTRS}"
  assert_success
}

# why: The created file must do what it says when git reads it
@test "_sync_gitattributes: a created file makes git check a script out with LF and a .bat with CRLF (base#2246)" {
  _repo
  _sync_gitattributes "${ATTRS}"
  [ "$(_attr eol run.sh)" = "lf" ]
  [ "$(_attr text run.sh)" = "auto" ]
  [ "$(_attr eol run.bat)" = "crlf" ]
  [ "$(_attr text img.png)" = "unset" ]
}

# ── An existing file with no block ─────────────────────────────────────────

# why: THE POINT OF THE PLACEMENT -- a repo's own binary / -text / eol rules
# must still decide the paths they name after the sync
@test "_sync_gitattributes: a repo's own rules still win after the block is added (base#2246)" {
  _repo
  printf '%s\n' '*.usd binary' '*.png binary' 'foo.txt -text' '*.ps1 text eol=crlf' > "${ATTRS}"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  [ "$(_attr text scene.usd)" = "unset" ]
  [ "$(_attr text foo.txt)" = "unset" ]
  [ "$(_attr eol setup.ps1)" = "crlf" ]
  [ "$(_attr eol run.sh)" = "lf" ]
  [ "$(_attr eol run.bat)" = "crlf" ]
}

# why: The block goes ABOVE the repo's lines -- below them it would be the
# last match and override every one
@test "_sync_gitattributes: the block is placed above the existing content (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  run head -n 1 -- "${ATTRS}"
  assert_output "$(_gitattributes_marker_begin)"
  run tail -n 1 -- "${ATTRS}"
  assert_output '*.usd binary'
}

# why: The repo's half is copied, not re-emitted -- the bytes after the block
# and its blank separator are the original file
@test "_sync_gitattributes: the existing content follows the block byte for byte (base#2246)" {
  printf '# mine\n*.usd binary\n\n  indented -text\n' > "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/before"
  _sync_gitattributes "${ATTRS}"
  _canonical_gitattributes_block > "${SCRATCH}/block"
  local _n
  _n="$(wc -l < "${SCRATCH}/block")"
  tail -n "+$(( _n + 2 ))" -- "${ATTRS}" > "${SCRATCH}/after_tail"
  run cmp -- "${SCRATCH}/before" "${SCRATCH}/after_tail"
  assert_success
}

# why: A last line with no newline is content the sync must not repair or
# lose
@test "_sync_gitattributes: an existing file with no final newline keeps exactly that (base#2246)" {
  printf '*.usd binary' > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  [ "$(tail -c 12 -- "${ATTRS}")" = '*.usd binary' ]
  [ "$(tail -c 1 -- "${ATTRS}" | od -An -c | tr -d ' ')" = 'y' ]
}

# why: An empty file has no content to separate the block from
@test "_sync_gitattributes: an empty existing file ends up holding exactly the block (base#2246)" {
  : > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  _canonical_gitattributes_block > "${SCRATCH}/block"
  run cmp -- "${SCRATCH}/block" "${ATTRS}"
  assert_success
}

# ── An existing block ──────────────────────────────────────────────────────

# why: Running the sync twice must not stack a second block
@test "_sync_gitattributes: a second run over its own output changes nothing (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/once"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  run cmp -- "${SCRATCH}/once" "${ATTRS}"
  assert_success
}

# why: A repo that hand-wrote the same block ahead of the upgrade must see no
# diff when the upgrade arrives
@test "_sync_gitattributes: a file already opening with the canonical block is left byte-identical (base#2246)" {
  { _canonical_gitattributes_block; printf '\n*.usd binary\n'; } > "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/before"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  run cmp -- "${SCRATCH}/before" "${ATTRS}"
  assert_success
}

# why: An up-to-date file must not even be rewritten -- the staging step asks
# whether this run wrote it
@test "_sync_gitattributes: an up-to-date file is not replaced (base#2246)" {
  _sync_gitattributes "${ATTRS}"
  local _inode_before _inode_after
  _inode_before="$(stat -c %i -- "${ATTRS}")"
  _sync_gitattributes "${ATTRS}"
  _inode_after="$(stat -c %i -- "${ATTRS}")"
  [ "${_inode_before}" = "${_inode_after}" ]
}

# why: The upgrade path -- a block an earlier release wrote is brought to the
# current text, and nothing outside it moves
@test "_sync_gitattributes: a stale block is rewritten in place and the lines around it are kept (base#2246)" {
  {
    printf '# header the repo wrote\n'
    _gitattributes_marker_begin
    printf '* text=auto\n'
    _gitattributes_marker_end
    printf '*.usd binary\n'
  } > "${ATTRS}"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  {
    printf '# header the repo wrote\n'
    _canonical_gitattributes_block
    printf '*.usd binary\n'
  } > "${SCRATCH}/want"
  run cmp -- "${SCRATCH}/want" "${ATTRS}"
  assert_success
}

# why: A rewrite must not leave a file the next run reads as malformed
@test "_sync_gitattributes: a rewritten block still carries exactly one marker pair (base#2246)" {
  {
    _gitattributes_marker_begin
    printf '* text=auto\n'
    _gitattributes_marker_end
  } > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  [ "$(grep -cxF -- "$(_gitattributes_marker_begin)" "${ATTRS}")" -eq 1 ]
  [ "$(grep -cxF -- "$(_gitattributes_marker_end)" "${ATTRS}")" -eq 1 ]
}

# why: The file's mode is the repo's, not mktemp's 0600
@test "_sync_gitattributes: a rewrite keeps the file's mode (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  chmod 0664 "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  [ "$(stat -c %a -- "${ATTRS}")" = "664" ]
}

# why: No temp file may be left beside the repo's own files
@test "_sync_gitattributes: leaves no temporary file behind (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  run find "${SCRATCH}" -mindepth 1 -maxdepth 1 -name '.gitattributes.?*'
  assert_output ""
}

# ── A file that opens with a UTF-8 byte order mark ─────────────────────────
#
# git skips a BOM only at the very start of .gitattributes. A block put above
# one would leave the mark at the head of the repo's first line, where it is
# part of that line's pattern and the rule stops matching anything.

# _bom -- print the three bytes of a UTF-8 byte order mark.
_bom() {
  printf '\357\273\277'
}

# why: THE DEFECT -- the rule on the line right after the mark must still
# decide its path once the block is added
@test "_sync_gitattributes: the first rule of a file opening with a BOM still wins after the block is added (base#2246)" {
  _repo
  { _bom; printf '%s\n' 'foo.txt -text' '*.usd binary'; } > "${ATTRS}"
  [ "$(_attr text foo.txt)" = "unset" ]
  run _sync_gitattributes "${ATTRS}"
  assert_success
  [ "$(_attr text foo.txt)" = "unset" ]
  [ "$(_attr text scene.usd)" = "unset" ]
  [ "$(_attr eol run.sh)" = "lf" ]
}

# why: The mark stays the file's first three bytes, once, and everything the
# repo wrote follows the block untouched
@test "_sync_gitattributes: a BOM stays at the very start, the block follows it, the content follows the block (base#2246)" {
  { _bom; printf '%s\n' 'foo.txt -text' '*.usd binary'; } > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  {
    _bom
    _canonical_gitattributes_block
    printf '\n'
    printf '%s\n' 'foo.txt -text' '*.usd binary'
  } > "${SCRATCH}/want"
  run cmp -- "${SCRATCH}/want" "${ATTRS}"
  assert_success
}

# why: The sync's own output for such a file opens with the mark and then the
# begin marker; a second run must read that as its block, not as a lone end
@test "_sync_gitattributes: a second run over a BOM file changes nothing (base#2246)" {
  { _bom; printf '%s\n' 'foo.txt -text'; } > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/once"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  run cmp -- "${SCRATCH}/once" "${ATTRS}"
  assert_success
}

# why: The upgrade path for a BOM file -- a stale block right behind the mark
# is rewritten, with the mark kept once and the repo's rules still deciding
@test "_sync_gitattributes: a stale block right behind a BOM is rewritten and the BOM is kept once (base#2246)" {
  _repo
  {
    _bom
    _gitattributes_marker_begin
    printf '* text=auto\n'
    _gitattributes_marker_end
    printf '\nfoo.txt -text\n'
  } > "${ATTRS}"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  {
    _bom
    _canonical_gitattributes_block
    printf '\nfoo.txt -text\n'
  } > "${SCRATCH}/want"
  run cmp -- "${SCRATCH}/want" "${ATTRS}"
  assert_success
  [ "$(_attr text foo.txt)" = "unset" ]
}

# why: With the repo's own lines between the mark and a stale block, the mark
# must be neither dropped nor written a second time
@test "_sync_gitattributes: a BOM file with lines above a stale block keeps one BOM and those lines (base#2246)" {
  {
    _bom
    printf '# header the repo wrote\n'
    _gitattributes_marker_begin
    printf '* text=auto\n'
    _gitattributes_marker_end
    printf '*.usd binary\n'
  } > "${ATTRS}"
  run _sync_gitattributes "${ATTRS}"
  assert_success
  {
    _bom
    printf '# header the repo wrote\n'
    _canonical_gitattributes_block
    printf '*.usd binary\n'
  } > "${SCRATCH}/want"
  run cmp -- "${SCRATCH}/want" "${ATTRS}"
  assert_success
}

# why: A file that is nothing but the mark has no content to separate from
# the block
@test "_sync_gitattributes: a file holding only a BOM ends up as the BOM and the block (base#2246)" {
  _bom > "${ATTRS}"
  _sync_gitattributes "${ATTRS}"
  { _bom; _canonical_gitattributes_block; } > "${SCRATCH}/want"
  run cmp -- "${SCRATCH}/want" "${ATTRS}"
  assert_success
}

# why: A malformed block is refused behind a mark exactly as without one, and
# the extra working file the mark needs must not be left behind
@test "_sync_gitattributes: a lone begin marker behind a BOM is refused, file unchanged (base#2246)" {
  { _bom; _gitattributes_marker_begin; printf '* text=auto eol=lf\n*.usd binary\n'; } > "${ATTRS}"
  _assert_refused_unchanged
}

# ── A malformed block ──────────────────────────────────────────────────────

# _assert_refused_unchanged -- the shape every malformed case shares: the
# sync fails, names the event, and the file is the bytes it started with.
_assert_refused_unchanged() {
  cp -- "${ATTRS}" "${SCRATCH}/before"
  run _sync_gitattributes "${ATTRS}"
  assert_failure
  assert_output --partial "malformed"
  run cmp -- "${SCRATCH}/before" "${ATTRS}"
  assert_success
  run find "${SCRATCH}" -mindepth 1 -maxdepth 1 -name '.gitattributes.?*'
  assert_output ""
}

# why: A begin marker with no end gives no place to stop; guessing deletes
# somebody's rule
@test "_sync_gitattributes: a begin marker with no end marker is refused, file unchanged (base#2246)" {
  { _gitattributes_marker_begin; printf '* text=auto eol=lf\n*.usd binary\n'; } > "${ATTRS}"
  _assert_refused_unchanged
}

# why: An end marker with no begin is the same corruption from the other side
@test "_sync_gitattributes: an end marker with no begin marker is refused, file unchanged (base#2246)" {
  { printf '*.usd binary\n'; _gitattributes_marker_end; } > "${ATTRS}"
  _assert_refused_unchanged
}

# why: Two blocks leave no single one to rewrite
@test "_sync_gitattributes: a repeated marker pair is refused, file unchanged (base#2246)" {
  { _canonical_gitattributes_block; printf '*.usd binary\n'; _canonical_gitattributes_block; } > "${ATTRS}"
  _assert_refused_unchanged
}

# why: An end marker ABOVE the begin marker delimits nothing
@test "_sync_gitattributes: an end marker above the begin marker is refused, file unchanged (base#2246)" {
  { _gitattributes_marker_end; printf '*.usd binary\n'; _gitattributes_marker_begin; } > "${ATTRS}"
  _assert_refused_unchanged
}

# ── A write that cannot be made ─────────────────────────────────────────────

# why: A writer that fails partway leaves a truncated draft; installing it
# would replace the repo's file with a shorter one
@test "_sync_gitattributes: a draft that cannot be fully written is abandoned, file unchanged (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/before"
  cat() { return 1; }
  run _sync_gitattributes "${ATTRS}"
  unset -f cat
  assert_failure
  assert_output --partial "could not write the rewrite"
  run cmp -- "${SCRATCH}/before" "${ATTRS}"
  assert_success
  run find "${SCRATCH}" -mindepth 1 -maxdepth 1 -name '.gitattributes.?*'
  assert_output ""
}

# why: With no temp file there is nowhere to compose the rewrite; the sync
# must say so and leave the repo's file alone
@test "_sync_gitattributes: a temp file that cannot be created is refused, file unchanged (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/before"
  mktemp() { return 1; }
  run _sync_gitattributes "${ATTRS}"
  unset -f mktemp
  assert_failure
  assert_output --partial "could not create a temporary file"
  run cmp -- "${SCRATCH}/before" "${ATTRS}"
  assert_success
}

# why: A rewrite that cannot take the file's mode would land a 0600 file over
# the repo's own; abandoning it is the only safe answer
@test "_sync_gitattributes: a rewrite that cannot take the file's mode is abandoned, file unchanged (base#2246)" {
  printf '%s\n' '*.usd binary' > "${ATTRS}"
  cp -- "${ATTRS}" "${SCRATCH}/before"
  chmod() { return 1; }
  run _sync_gitattributes "${ATTRS}"
  unset -f chmod
  assert_failure
  assert_output --partial "could not give the rewrite the mode"
  run cmp -- "${SCRATCH}/before" "${ATTRS}"
  assert_success
  run find "${SCRATCH}" -mindepth 1 -maxdepth 1 -name '.gitattributes.?*'
  assert_output ""
}

# ── Wiring ─────────────────────────────────────────────────────────────────

# why: _log_* is strict -- an unregistered event prints the registry's refusal
# instead of the message that says what is wrong with the file
@test "gitattributes: the events the sync can raise are registered (base#2246)" {
  local _events="/source/dist/script/docker/lib/log-events.txt"
  assert_spec_subject "${_events}" "the event registry _log_* refuses unlisted bodies against"
  run grep -cxE 'gitattributes_managed_block_invalid|gitattributes_sync_failed' "${_events}"
  assert_output "2"
}
