#!/usr/bin/env bats
#
# The GitHub org this repo lives in, and the GHCR namespace its tooling
# image is published under, have one name: ycpss91255-lab. The two org
# names before it were retired without redirects that can be relied on --
# the API answers 404 for the old org and the old GHCR namespace issues no
# pull token -- so a reference left behind is not stale prose, it is a
# clone, a `uses:`, an `actions/checkout` or a `docker pull` that fails.
#
# Most of those references reach a consumer: upstream.sh, init.sh and
# check-base-version.sh are vendored into every downstream `.base/`, and
# the workers are called by their `uses:` lines. So the tree as a whole is
# scanned, not a list of the files known to carry one today.
#
# The historical record keeps what it said when it was written: a released
# changelog section and an ADR describe the tree of their day, and
# rewriting them falsifies it (doc/changelog/CONVENTIONS.md). Those two
# directories are the only exemption.
#
# why: The org was renamed and the old names no longer resolve, so a
# retired org name anywhere in the shipped or tested tree is a clone, an
# action call or an image pull that fails; the scan covers the whole
# checkout apart from the historical record (released changelog sections,
# ADRs) and the build and cache output a run leaves behind.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
  assert_spec_subject "${ROOT}/dist/script/base/upstream.sh" \
    "the upstream definition every consumer's .base/ resolves base through"
  # Spelled as an alternation so this file's own text never matches it.
  RETIRED_RE='ycpss91255-(docker|research)'
  # Run output, editor and agent state: directories .gitignore lists, so a
  # file lives in one untracked unless forced in. Held to that below.
  IGNORED_DIRS=(log coverage coverage-shards multi_run .config-gen-bin
    __pycache__ .prev-release .claude .vscode .idea)
}

# _scan_retired
#   Every line under ROOT naming a retired org, as <path>:<line>:<text>.
#   The enumeration is grep -r, not git ls-files: /source may be a mounted
#   worktree whose .git points at a path the container cannot see. The
#   exclusions are the historical record plus what .gitignore keeps out of
#   the tree (run output, editor and agent state).
_scan_retired() {
  grep -rnIiE "${RETIRED_RE}" "${ROOT}" \
    --exclude-dir=.git \
    --exclude-dir=adr \
    --exclude-dir=changelog \
    "${IGNORED_DIRS[@]/#/--exclude-dir=}" \
    --exclude='.env' --exclude='.env.local' --exclude='.setup.conf.local' \
    --exclude='CLAUDE.md'
}

# why: The exemption is the historical record and nothing else -- an
# exclusion that also matched a live directory named the same would hide
# exactly what this spec looks for.
@test "org name: only doc/adr and doc/changelog are named adr or changelog (base#2106)" {
  run bash -c "find '${ROOT}' -path '${ROOT}/.git' -prune -o -type d \
    \( -name adr -o -name changelog \) -print | sort"
  assert_success
  assert_output "${ROOT}/doc/adr
${ROOT}/doc/changelog"
}

# why: The scan itself must be able to find a hit, or a green result
# says nothing: a fixture tree carrying one retired name has to be
# reported with its path.
@test "org name: the scan reports a retired name it is shown (base#2106)" {
  ROOT="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${ROOT}/script" "${ROOT}/doc/adr"
  printf 'ok ycpss91255-lab/base\n' > "${ROOT}/script/fine.sh"
  printf 'x=%s\n' "ycpss91255-""docker/base" > "${ROOT}/script/stale.sh"
  printf 'history: %s\n' "ycpss91255-""docker/base" > "${ROOT}/doc/adr/0001.md"
  run _scan_retired
  assert_success
  assert_output --partial "${ROOT}/script/stale.sh:1:"
  refute_output --partial 'fine.sh'
  refute_output --partial '/doc/adr/'
}

# why: A checkout can hold untracked editor and agent state, whole stale
# worktrees under .claude included; reporting a name found there fails a
# local run over files that are not in the tree (base#2119)
@test "org name: the scan passes over ignored editor and agent state (base#2119)" {
  ROOT="${BATS_TEST_TMPDIR}/tree"
  local _stale="ycpss91255-""docker/base" _dir
  for _dir in .claude/worktrees/x .vscode .idea dist/claude; do
    mkdir -p "${ROOT}/${_dir}"
    printf '%s\n' "${_stale}" > "${ROOT}/${_dir}/stale.txt"
  done
  run _scan_retired
  assert_success
  assert_output "${ROOT}/dist/claude/stale.txt:1:${_stale}"
}

# why: A directory may be passed over because git ignores it and for no other
# reason; an excluded name .gitignore does not list could be a tracked
# directory, and the scan would silently stop covering it (base#2119)
@test "org name: every excluded run or editor directory is one .gitignore lists (base#2119)" {
  local _dir
  (( ${#IGNORED_DIRS[@]} > 0 )) || fail "IGNORED_DIRS is empty, so this checks nothing"
  for _dir in "${IGNORED_DIRS[@]}"; do
    grep -qxF -e "${_dir}" -e "${_dir}/" "${ROOT}/.gitignore" \
      || fail "${_dir} is excluded from the scan but .gitignore does not list it"
  done
}

# why: The live tree names only the current org: no file outside the
# historical record carries a retired one.
@test "org name: the tree outside the historical record names no retired org (base#2106)" {
  run _scan_retired
  assert_failure 1
  assert_output ''
}
