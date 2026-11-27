#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/tracked_crlf.sh -- the "no tracked
# text file is stored with CRLF line endings" lint. Driven over throwaway
# git repositories built per case, so the cases pin the rule (index side,
# `-text` the only exemption, no vacuous pass) rather than the state of the
# live tree; the live tree is the lint job's assertion to make, not this
# spec's.
#
# why: Unit tests for `script/test/drivers/tracked_crlf.sh`
# (`_run_tracked_crlf`, refs base#2246), the "no tracked text file is
# stored with CRLF line endings" lint. The root `.gitattributes` rule
# `* text=auto eol=lf` fixes what a checkout holds, but `text=auto` leaves
# a file alone once the copy in the index carries a CR, so a CRLF file
# committed before the rule stays CRLF with nothing reporting it. The lint
# reads the INDEX side of `git ls-files --eol`, which is the same bytes on
# a Windows clone and on a CI runner. `-text` in `.gitattributes` is the
# only exemption -- the mark this repo's deliberate CRLF fixtures already
# carry -- and `eol=crlf` is not one. Driven over throwaway repositories,
# with a case for each way the lint could go green having read nothing.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # canonical_ignore_sync_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/tracked_crlf.sh

  # No user or system git configuration reaches the fixture: a
  # core.autocrlf or a global attributes file on the machine running the
  # suite would decide what `git add` stores, which is the very thing
  # under test.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1

  SCRATCH="$(mktemp -d)"
  REPO_ROOT="${SCRATCH}"
  git -C "${SCRATCH}" init -q
  git -C "${SCRATCH}" config core.autocrlf false
}

teardown() {
  if [[ -n "${SCRATCH:-}" ]]; then
    rm -rf "${SCRATCH}"
  fi
}

# _plant <relpath> <printf-format> -- write a file into the fixture tree.
# The body is a printf FORMAT so a case spells its own line endings
# (`'a\r\nb\r\n'`) where a reader can see them.
_plant() {
  local _f="${SCRATCH}/${1}"
  mkdir -p "$(dirname "${_f}")"
  # shellcheck disable=SC2059
  printf "${2}" > "${_f}"
}

# _track <relpath>... -- add the named paths to the fixture's index. Only
# the index is read by the lint, so no commit is needed.
_track() {
  git -C "${SCRATCH}" add -- "$@"
}

# ── The control group ──────────────────────────────────────────────────────

# why: A tree of LF files must not be reported
@test "_run_tracked_crlf: passes when every tracked file is stored with LF (base#2246)" {
  _plant a.sh 'one\ntwo\n'
  _plant doc/b.md 'three\n'
  _track a.sh doc/b.md
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tracked CRLF lint: clean"* ]]
}

# why: The clean report states how many files it read, so a run over nothing
# cannot look like a run over the tree
@test "_run_tracked_crlf: the clean report names how many tracked files it examined (base#2246)" {
  _plant a.sh 'one\n'
  _plant b.sh 'two\n'
  _plant c.sh 'three\n'
  _track a.sh b.sh c.sh
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"3 tracked files"* ]]
}

# ── The rule ───────────────────────────────────────────────────────────────

# why: The defect itself -- a text file stored with CRLF
@test "_run_tracked_crlf: FAILS on a tracked file stored with CRLF, naming it (base#2246)" {
  _plant ok.sh 'one\ntwo\n'
  _plant bad.sh 'one\r\ntwo\r\n'
  _track ok.sh bad.sh
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bad.sh: stored with crlf line endings"* ]]
  [[ "${output}" != *"ok.sh: stored"* ]]
}

# why: A file with only SOME lines ending in CRLF breaks the same readers
@test "_run_tracked_crlf: FAILS on a tracked file with mixed line endings (base#2246)" {
  _plant mixed.sh 'one\r\ntwo\nthree\r\n'
  _track mixed.sh
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"mixed.sh: stored with mixed line endings"* ]]
}

# why: Every offender is reported, so one run is the whole list
@test "_run_tracked_crlf: names EVERY offender, not only the first (base#2246)" {
  _plant a.sh 'x\r\n'
  _plant sub/b.bats 'y\r\n'
  _plant c.md 'z\n'
  _track a.sh sub/b.bats c.md
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"a.sh: stored with crlf line endings"* ]]
  [[ "${output}" == *"sub/b.bats: stored with crlf line endings"* ]]
  [[ "${output}" == *"2 of 3 tracked files"* ]]
}

# why: The report must name a path a reader can hand straight back to git
@test "_run_tracked_crlf: a path with a space is named verbatim, unquoted (base#2246)" {
  _plant 'dir with space/my file.txt' 'x\r\n'
  _track 'dir with space/my file.txt'
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dir with space/my file.txt: stored with crlf line endings"* ]]
}

# ── The exemption ──────────────────────────────────────────────────────────

# why: A byte-exact CRLF fixture marked `-text` is content, not a finding
@test "_run_tracked_crlf: a CRLF file whose path is marked -text is exempt (base#2246)" {
  _plant .gitattributes 'fixture/crlf.toml -text\n'
  _plant fixture/crlf.toml 'a = 1\r\nb = 2\r\n'
  _track .gitattributes fixture/crlf.toml
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tracked CRLF lint: clean"* ]]
}

# why: The `binary` macro carries -text, so it exempts the same way
@test "_run_tracked_crlf: a CRLF file whose path is marked binary is exempt (base#2246)" {
  _plant .gitattributes '*.dat binary\n'
  _plant blob.dat 'a\r\nb\r\n'
  _track .gitattributes blob.dat
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
}

# why: The exemption is per path -- one -text line must not excuse a sibling
@test "_run_tracked_crlf: a -text line does not exempt a different path (base#2246)" {
  _plant .gitattributes 'fixture/crlf.toml -text\n'
  _plant fixture/crlf.toml 'a = 1\r\n'
  _plant fixture/other.toml 'a = 1\r\n'
  _track .gitattributes fixture/crlf.toml fixture/other.toml
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"fixture/other.toml: stored with crlf line endings"* ]]
  [[ "${output}" != *"fixture/crlf.toml: stored"* ]]
}

# why: `eol=crlf` is a checkout rule, not an exemption -- such a file is still
# stored with LF, and one that is not needs the same renormalize
@test "_run_tracked_crlf: eol=crlf does NOT exempt a file already stored with CRLF (base#2246)" {
  # Staged BEFORE the attribute exists, which is the state a repo is in
  # when the rule arrives after the file.
  _plant run.bat 'echo one\r\necho two\r\n'
  _track run.bat
  _plant .gitattributes '*.bat text eol=crlf\n'
  _track .gitattributes
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run.bat: stored with crlf line endings"* ]]
}

# why: The ordinary Windows-script case must stay green -- CRLF on disk, LF in
# the index
@test "_run_tracked_crlf: an eol=crlf file normalised on add passes although its working copy is CRLF (base#2246)" {
  _plant .gitattributes '*.bat text eol=crlf\n'
  _plant run.bat 'echo one\r\necho two\r\n'
  _track .gitattributes run.bat
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
}

# ── What is not a finding ──────────────────────────────────────────────────

# why: Only the index is judged; a stray untracked file is not this repo's
# content
@test "_run_tracked_crlf: an untracked CRLF file is not reported (base#2246)" {
  _plant a.sh 'one\n'
  _track a.sh
  _plant scratch.txt 'x\r\n'
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
}

# why: A file git detects as binary has no line ending to get wrong
@test "_run_tracked_crlf: a file git detects as binary is not reported (base#2246)" {
  _plant a.sh 'one\n'
  _plant img.raw 'a\000b\r\nc\r\n'
  _track a.sh img.raw
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
}

# why: An empty tracked file is a real file with nothing to judge
@test "_run_tracked_crlf: an empty tracked file is counted and not reported (base#2246)" {
  : > "${SCRATCH}/.gitkeep"
  _plant a.sh 'one\n'
  _track .gitkeep a.sh
  run _run_tracked_crlf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 tracked files"* ]]
}

# ── What makes a clean run mean something ──────────────────────────────────

# why: A directory with no index has no answer, and no answer is not a pass
@test "_run_tracked_crlf: a tree that is not a git work tree DIES rather than passing (base#2246)" {
  local _plain
  _plain="$(mktemp -d)"
  printf 'x\r\n' > "${_plain}/a.sh"
  REPO_ROOT="${_plain}"
  # GIT_CEILING_DIRECTORIES stops git walking up out of the fixture into
  # whatever repository the temp dir happens to sit under.
  GIT_CEILING_DIRECTORIES="$(dirname "${_plain}")" run _run_tracked_crlf
  rm -rf "${_plain}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"failed under"* ]]
  [[ "${output}" != *"tracked CRLF lint: clean"* ]]
}

# why: A repository tracking nothing would make the loop visit nothing
@test "_run_tracked_crlf: a work tree with no tracked file DIES rather than passing (base#2246)" {
  _plant untracked.sh 'x\r\n'
  run _run_tracked_crlf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"listed no tracked file"* ]]
}

# why: A worktree checkout bind-mounted without its gitdir cannot be read at
# all; the driver must say it examined nothing instead of claiming clean
@test "_run_tracked_crlf: an unreachable worktree gitdir is reported NOT RUN, never clean (base#2246)" {
  local _wt
  _wt="$(mktemp -d)"
  printf 'gitdir: /nonexistent/main/.git/worktrees/wt\n' > "${_wt}/.git"
  printf 'x\r\n' > "${_wt}/a.sh"
  REPO_ROOT="${_wt}"
  run _run_tracked_crlf
  rm -rf "${_wt}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tracked CRLF lint: NOT RUN"* ]]
  [[ "${output}" == *"--tracked-crlf-only"* ]]
  [[ "${output}" != *"tracked CRLF lint: clean"* ]]
}

# why: The NOT RUN branch is for a pointer that does not resolve; a `.git`
# file that is not a pointer at all must still be refused
@test "_run_tracked_crlf: a .git file that is not a gitdir pointer DIES rather than being skipped (base#2246)" {
  local _odd
  _odd="$(mktemp -d)"
  printf 'not a pointer\n' > "${_odd}/.git"
  REPO_ROOT="${_odd}"
  GIT_CEILING_DIRECTORIES="$(dirname "${_odd}")" run _run_tracked_crlf
  rm -rf "${_odd}"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"NOT RUN"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Wiring
# ════════════════════════════════════════════════════════════════════
#
# The guards every lint spec in this tree carries. A driver can be
# written, specced and green while gating nothing at all -- the gap
# base#1113 names -- and these are what refuse that for this lint:
# membership in the dispatcher's table, exactly one CI group, a failure
# id a reader can look up, and a dispatch arm.

# why: A lint nobody runs is a comment
@test "tracked-crlf: is a member of the lint phase's tool table" {
  # PARSED, never sourced: sourcing test.sh drags in the whole lib chain,
  # which reads BASH_SOURCE unguarded, and under the kcov-instrumented
  # bash of the coverage shard that aborts.
  local _test_sh="/source/script/test/test.sh"
  assert_spec_subject "${_test_sh}" "the test runner whose _LINT_TOOLS table this lint joins"
  run awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${_test_sh}"
  assert_success
  assert_line "tracked-crlf"
}

# why: One lint group and exactly one, because none gates nothing and two pays
# twice
@test "tracked-crlf: has a lint-static CI join" {
  local _wf="/source/.github/workflows/self-test.yaml"
  assert_spec_subject "${_wf}" "the workflow whose lint-static groups this lint joins"
  local _hits
  _hits="$(lint_group_hits tracked-crlf "${_wf}")"
  [ "${_hits}" -eq 1 ] \
    || fail "the tracked-crlf lint is in ${_hits} lint-static groups; in none, a file committed with CRLF reaches main with nothing reading the index"
}

# why: An unregistered event id is an anonymous exit: the log line carries no
# name a reader can look up
@test "tracked-crlf: its failure event id is registered" {
  run grep -qx 'ci_tracked_crlf' /source/dist/script/docker/lib/log-events.txt
  assert_success
}

# why: The driver must be dispatchable by the name the table carries
@test "tracked-crlf: the dispatcher has a case arm for it (base#2246)" {
  local _test_sh="/source/script/test/test.sh"
  assert_spec_subject "${_test_sh}" "the dispatcher whose _run_lint_tool arm this lint needs"
  run grep -qE '^[[:space:]]*tracked-crlf\)[[:space:]]*_run_tracked_crlf' \
    "${_test_sh}"
  assert_success
}

# why: The rule the lint cites must be the one the root .gitattributes opens
# with; a lint guarding a rule the file no longer carries guards nothing
@test "tracked-crlf: base's own root .gitattributes carries the LF rule the lint cites (base#2246)" {
  local _attrs="/source/.gitattributes"
  assert_spec_subject "${_attrs}" "the attributes file whose text rule this lint backs"
  run grep -qxF '* text=auto eol=lf' "${_attrs}"
  assert_success
}
