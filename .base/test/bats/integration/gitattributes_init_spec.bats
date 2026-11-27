#!/usr/bin/env bats
#
# Integration: the .gitattributes line-ending block via init.sh (new-repo
# and existing-repo paths).
#
# The lib functions are unit-tested in
# test/bats/unit/gitattributes_sync_spec.bats; this spec runs the real
# init.sh over a consumer and asks git which rule wins afterwards.
#
# why: End-to-end coverage that wires `lib/gitattributes.sh` through
# `init.sh`'s new-repo and existing-repo paths (base#2246). A consumer had
# no line-ending rule, so a Windows clone on the default `core.autocrlf`
# checked scripts out with CRLF. The existing-repo cases start from a
# `.gitattributes` a repo already wrote -- binary asset types, a `-text`
# fixture, a CRLF script type -- because the block must land ABOVE those
# lines: in `.gitattributes` the last match wins, and a block appended
# below would override every one of them. Standalone fixture, as
# `gitignore_sync_spec.bats` is, because the sync needs the real `init.sh`.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  TMP_ROOT="$(mktemp -d)"
  REPO_DIR="${TMP_ROOT}/myrepo"
  mkdir -p "${REPO_DIR}/.base"
  cp -a /source/. "${REPO_DIR}/.base/"
  # A real vendored subtree never carries `.git`; see gitignore_sync_spec.
  rm -rf "${REPO_DIR}/.base/.git"
  cd "${REPO_DIR}"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitattributes.sh
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# _attr <attribute> <path> -- the value git resolves for <attribute> on
# <path> in the consumer.
_attr() {
  git -C "${REPO_DIR}" check-attr "${1}" -- "${2}" | sed 's/.*: //'
}

# _seed_existing_repo -- a consumer init.sh takes the existing-repo path
# for (a Dockerfile is present), already a git repository, with whatever
# .gitattributes the calling case planted committed alongside.
_seed_existing_repo() {
  echo "FROM alpine" > "${REPO_DIR}/Dockerfile"
  git -C "${REPO_DIR}" init -q -b main
  git -C "${REPO_DIR}" config user.email t@t
  git -C "${REPO_DIR}" config user.name t
  git -C "${REPO_DIR}" config core.autocrlf false
  git -C "${REPO_DIR}" add -A
  git -C "${REPO_DIR}" commit -q -m "init"
}

# ── new-repo path ──────────────────────────────────────────────────────────

# why: A new repo starts with the rule, without anyone writing it
@test "init.sh new-repo: .gitattributes is created holding exactly the canonical block (base#2246)" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.gitattributes" ]
  _canonical_gitattributes_block > "${TMP_ROOT}/block"
  run cmp -- "${TMP_ROOT}/block" "${REPO_DIR}/.gitattributes"
  assert_success
}

# why: The file init.sh wrote must make git do what the block says
@test "init.sh new-repo: git resolves LF for a script and CRLF for a .bat (base#2246)" {
  bash .base/dist/script/base/init.sh
  git -C "${REPO_DIR}" init -q
  [ "$(_attr eol script/run.sh)" = "lf" ]
  [ "$(_attr eol Dockerfile)" = "lf" ]
  [ "$(_attr eol tool.bat)" = "crlf" ]
}

# ── existing-repo path ─────────────────────────────────────────────────────

# why: A repo with no .gitattributes at all is the common case -- the resync
# must give it one
@test "init.sh existing-repo: creates .gitattributes when the repo has none (base#2246)" {
  _seed_existing_repo
  bash .base/dist/script/base/init.sh
  _canonical_gitattributes_block > "${TMP_ROOT}/block"
  run cmp -- "${TMP_ROOT}/block" "${REPO_DIR}/.gitattributes"
  assert_success
}

# why: THE POINT -- an asset repo's own binary / -text / CRLF rules must still
# decide the paths they name after the resync adds the block
@test "init.sh existing-repo: the repo's own attribute rules still win after the resync (base#2246)" {
  printf '%s\n' '*.usd binary' '*.png binary' 'foo.txt -text' '*.ps1 text eol=crlf' \
    > "${REPO_DIR}/.gitattributes"
  _seed_existing_repo
  bash .base/dist/script/base/init.sh

  [ "$(_attr text x.usd)" = "unset" ]
  [ "$(_attr text foo.txt)" = "unset" ]
  [ "$(_attr eol a.ps1)" = "crlf" ]
  [ "$(_attr eol a.sh)" = "lf" ]
  [ "$(_attr text a.sh)" = "auto" ]
  [ "$(_attr eol a.bat)" = "crlf" ]
}

# why: The repo's lines are copied, never re-emitted or reordered
@test "init.sh existing-repo: the repo's own lines survive verbatim below the block (base#2246)" {
  printf '%s\n' '# asset types' '*.usd binary' 'foo.txt -text' > "${REPO_DIR}/.gitattributes"
  cp -- "${REPO_DIR}/.gitattributes" "${TMP_ROOT}/before"
  _seed_existing_repo
  bash .base/dist/script/base/init.sh

  run head -n 1 -- "${REPO_DIR}/.gitattributes"
  assert_output "$(_gitattributes_marker_begin)"
  _canonical_gitattributes_block > "${TMP_ROOT}/block"
  local _n
  _n="$(wc -l < "${TMP_ROOT}/block")"
  tail -n "+$(( _n + 2 ))" -- "${REPO_DIR}/.gitattributes" > "${TMP_ROOT}/after_tail"
  run cmp -- "${TMP_ROOT}/before" "${TMP_ROOT}/after_tail"
  assert_success
}

# why: A repo that hand-wrote the block ahead of the upgrade must see no diff
# when the upgrade's resync arrives
@test "init.sh existing-repo: a .gitattributes already opening with the canonical block is left byte-identical (base#2246)" {
  { _canonical_gitattributes_block; printf '\n*.usd binary\n'; } > "${REPO_DIR}/.gitattributes"
  cp -- "${REPO_DIR}/.gitattributes" "${TMP_ROOT}/before"
  _seed_existing_repo
  bash .base/dist/script/base/init.sh
  run cmp -- "${TMP_ROOT}/before" "${REPO_DIR}/.gitattributes"
  assert_success
  run git -C "${REPO_DIR}" status --porcelain -- .gitattributes
  assert_output ""
}

# why: Re-running the resync must not stack a second block
@test "init.sh existing-repo: a second run produces no .gitattributes change (base#2246)" {
  printf '%s\n' '*.usd binary' > "${REPO_DIR}/.gitattributes"
  _seed_existing_repo
  bash .base/dist/script/base/init.sh
  cp -- "${REPO_DIR}/.gitattributes" "${TMP_ROOT}/first"
  bash .base/dist/script/base/init.sh
  run cmp -- "${TMP_ROOT}/first" "${REPO_DIR}/.gitattributes"
  assert_success
}

# why: The resync changes the RULE, not the repository's content -- a file
# already committed with CRLF is the repo's to renormalize, in its own commit
@test "init.sh existing-repo: the resync does not renormalize files already committed (base#2246)" {
  printf 'one\r\ntwo\r\n' > "${REPO_DIR}/legacy.txt"
  _seed_existing_repo
  bash .base/dist/script/base/init.sh
  run git -C "${REPO_DIR}" ls-files --eol -- legacy.txt
  assert_output --partial "i/crlf"
  run git -C "${REPO_DIR}" diff --cached --name-only -- legacy.txt
  assert_output ""
}
