#!/usr/bin/env bats
#
# check_selection_spec.bats -- "a pull request runs only the checks its
# diff can affect, and a path nobody classified runs every one of them",
# base#1584.
#
# why: classify gave every heavy job one answer, code_changed, so a PR
# that touched one config-gen spec and two docs ran config-gen and all
# twelve coverage shards (112 min wall). script/ci/check_selection.sh
# maps a diff to one answer per classify-gated job, and
# script/ci/selection_at_base.sh runs the BASE side's copy of it, so a
# PR cannot narrow its own checks by editing the map.
#
# The map reads the PR's changed paths NUL-separated from stdin
# (`--paths`, the shape `git diff -z --name-only` prints) or diffs
# `--base <ref>...HEAD` itself, and prints one `<job>=<true|false>` line
# per gated job. Expected values come from the issue text, what each job
# reads, git's own behaviour and the probes cited per case, never from
# the map's own output.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SELECTION_SH=/source/script/ci/check_selection.sh
  AT_BASE_SH=/source/script/ci/selection_at_base.sh
}

# The map's names, in its output order: one per select_* key the diff
# decides. config-gen stands for config-gen-gates.
GATED_JOBS="config-gen coverage coverage-gate acceptance system worker-selftest shellcheck hadolint bats-fragile test-tools-image-arm64"
# Every gated job but config-gen: what a config-gen deny-list path runs.
NOT_CONFIG_GEN="coverage coverage-gate acceptance system worker-selftest shellcheck hadolint bats-fragile test-tools-image-arm64"

# _select <event> <path>...
#   Runs the map with <path>... as the whole diff of a <event> run.
_select() {
  local _event="${1:?BUG: _select expects an event}"
  shift
  printf '%s\0' "$@" | bash "${SELECTION_SH}" --event "${_event}" --paths
}

# _expect [all | <job>...] -- one line per map name in the map's order, each job
#   `false` unless named here, or every job `true` for `all`.
_expect() {
  local _job _v _out=""
  for _job in ${GATED_JOBS}; do
    _v=false
    [[ " $* " == *" all "* || " $* " == *" ${_job} "* ]] && _v=true
    _out+="${_job}=${_v}"$'\n'
  done
  printf '%s' "${_out%$'\n'}"
}

# _assert_all_selected [<reason>] -- the last `run` printed every job true,
#   exited 0, and, when <reason> is given, first named it on stderr (the
#   caller merged stderr into the output).
_assert_all_selected() {
  assert_success
  local _want
  _want="$(_expect all)"
  if [[ -n "${1:-}" ]]; then
    _want="check_selection_select_all reason=${1}"$'\n'"${_want}"
  fi
  assert_output "${_want}"
}

# _scratch_repo -- a git repo in BATS_TEST_TMPDIR holding a real copy of
#   the selection files on main; cd's into it.
_scratch_repo() {
  local _r="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_r}/script/ci" "${_r}/doc" "${_r}/dist/script/base"
  cp /source/script/ci/check_selection.sh /source/script/ci/config_gen_paths.sh \
    /source/script/ci/selection_at_base.sh "${_r}/script/ci/"
  printf 'seed\n' > "${_r}/doc/seed.md"
  printf 'init\n' > "${_r}/dist/script/base/init.sh"
  git -C "${_r}" init -q -b main
  git -C "${_r}" add -A
  git -C "${_r}" -c user.name=t -c user.email=t@t commit -q -m base
  cd "${_r}"
}

# _commit <message> -- commits everything in the current repo.
_commit() {
  git add -A
  git -c user.name=t -c user.email=t@t commit -q -m "$1"
}

# why: the issue's fail-closed rule, "an unknown path selects every job".
@test "check_selection: a pull request touching only a path no row names selects every gated job (base#1584)" {
  run _select pull_request zz-new/thing.txt
  assert_success
  assert_output "$(_expect all)"
}

# why: the docs allow-list classify's code_changed gate already uses
# (doc/**, README.md, LICENSE, CONTEXT.md) and the issue's "a docs-only
# PR": a docs-only diff affects no gated job.
@test "check_selection: a pull request touching only docs selects no gated job (base#1584)" {
  run _select pull_request doc/x.md README.md LICENSE CONTEXT.md
  assert_success
  assert_output "$(_expect)"
}

# why: classify reads these names. A release-only job is not one: no path's
# answer for it could be used, because no change runs it.
@test "check_selection: --jobs prints the map names, one per select key the diff decides (base#1584, base#2110, base#2177)" {
  run bash "${SELECTION_SH}" --jobs
  assert_success
  assert_output "$(tr ' ' '\n' <<<"${GATED_JOBS}")"
}

# why: only a pull request may narrow the selection.
@test "check_selection: a push run selects every gated job even when its diff is docs only (base#1584)" {
  run --separate-stderr _select push doc/x.md
  assert_success
  assert_output "$(_expect all)"
  assert_equal "${stderr}" "check_selection_select_all reason=non_pr"
}

# why: cycle 15. dist/script/base/init.sh and
# script/release/changelog_index.sh are non-readers in the traced
# config-gen host run (config_gen_paths_spec.bats re-runs the tracer), and
# neither is in _rp_copy (script/test/config_gen_redpath.sh). Each drops
# config-gen and keeps every other job, so the deny list is not too small
# to ever narrow.
@test "check_selection: a deny-list path drops config-gen and keeps every other gated job (base#1584)" {
  local _p
  for _p in dist/script/base/init.sh script/release/changelog_index.sh; do
    run _select pull_request "${_p}"
    assert_success
    assert_output "$(_expect ${NOT_CONFIG_GEN})"
  done
}

# why: cycle 16 (R2-F1, RR4-F3). A path the deny list does not name
# exactly -- a new file, a file in a new directory -- runs config-gen.
# The first two printed config-gen=false through the old glob rows
# (review round 1, F1).
@test "check_selection: a new or nested path under dist/ or script/ runs config-gen (base#1584)" {
  local _p
  for _p in dist/script/base/new_helper.sh script/release/new_tool.sh \
            dist/script/base/newdir/x.sh; do
    run _select pull_request "${_p}"
    assert_success
    assert_output "$(_expect all)"
  done
}

# why: cycle 16, the rename half. `git diff --no-renames` lists a rename
# as its delete and its add. The delete side alone, a deny-list path,
# drops config-gen; the add side is a new name, so the rename runs it.
@test "check_selection: a renamed deny-list file runs config-gen (base#1584)" {
  _scratch_repo
  run _select pull_request dist/script/base/init.sh
  assert_output "$(_expect ${NOT_CONFIG_GEN})"
  git checkout -q -b pr
  git mv dist/script/base/init.sh dist/script/base/init2.sh
  _commit rename
  run bash "${SELECTION_SH}" --event pull_request --base main
  assert_success
  assert_output "$(_expect all)"
}

# why: cycle 17 (RR4-F2). script/build.sh is a tracked symlink (mode
# 120000, -> ../dist/script/docker/wrapper/build.sh), never a deny entry,
# so it runs every job (it printed config-gen=false before, review round
# 1, F1).
@test "check_selection: a tracked symlink path selects every gated job (base#1584)" {
  run _select pull_request script/build.sh
  assert_success
  assert_output "$(_expect all)"
}

# why: cycle 18 (RR3-F4, RR6-F2). A record holding a control byte is not
# one path git printed under -z: bash `case` `*` matches a newline, so
# `doc/a.md<LF>script/x.sh` was ONE record that matched the doc row and
# selected nothing (review round 1, F4). Each such input selects every
# job and names bad_record.
@test "check_selection: a record holding a control byte selects every gated job (base#1584)" {
  local _in
  for _in in 'dist/script/base/init.sh\n' 'doc/a.md\nscript/x.sh\n' \
             'test/bats/unit/a_spec.bats\nx_spec.bats' 'doc/a.md\tx\0'; do
    run --separate-stderr bash -c "printf '${_in}' | bash '${SELECTION_SH}' --event pull_request --paths"
    assert_success
    assert_output "$(_expect all)"
    [[ "${stderr}" == "check_selection_select_all reason=bad_record" ]] \
      || fail "input '${_in}': stderr '${stderr}'"
  done
}

# why: cycle 18. Empty stdin is no diff the map read, so nothing may be
# dropped; it printed all false before (review round 1, F4).
@test "check_selection: empty input selects every gated job (base#1584)" {
  run bash -c "bash '${SELECTION_SH}' --event pull_request --paths </dev/null 2>&1"
  _assert_all_selected no_paths
}

# why: cycle 18. `read -d ''` drops a final record with no NUL, so
# `doc/a.md<NUL>zz/x` read as docs only. zz/x is an unknown path.
@test "check_selection: an unterminated last record is still read (base#1584)" {
  run bash -c "printf 'doc/a.md\0zz/x' | bash '${SELECTION_SH}' --event pull_request --paths"
  assert_success
  assert_output "$(_expect all)"
}

# why: cycle 18's control: a clean docs record still selects nothing, so
# the control-byte check does not reject clean input.
@test "check_selection: a clean NUL-terminated docs record selects nothing (base#1584)" {
  run --separate-stderr bash -c "printf 'doc/a.md\0' | bash '${SELECTION_SH}' --event pull_request --paths"
  assert_success
  assert_output "$(_expect)"
  assert_equal "${stderr}" ""
}

# why: cycle 19 (RR3-F3). An empty base reads as HEAD to git (`git diff
# "...HEAD"` exits 0 with no output, measured), a missing ref names no
# commit, base == HEAD is a diff with no path, and an orphan HEAD has no
# merge base (`git diff main...HEAD` exits 128 there, measured). Each
# selects every job and names its reason.
@test "check_selection: an unreadable diff base selects every gated job with its reason (base#1584)" {
  _scratch_repo
  run bash -c "bash '${SELECTION_SH}' --event pull_request --base '' 2>&1"
  _assert_all_selected empty_base
  run bash -c "bash '${SELECTION_SH}' --event pull_request --base no-such-ref 2>&1"
  _assert_all_selected bad_base
  run bash -c "bash '${SELECTION_SH}' --event pull_request --base main 2>&1"
  _assert_all_selected no_paths
  git checkout -q --orphan lone
  _commit orphan
  run bash -c "bash '${SELECTION_SH}' --event pull_request --base main 2>&1"
  _assert_all_selected no_merge_base
}

# why: base#2110. With two merge bases the three-dot diff is taken from one
# of them, so it can hide a change the merge would make (a pull request that
# holds a commit already on the base and its revert, seen from a criss-cross
# history). More than one merge base selects every job.
@test "check_selection: more than one merge base selects every gated job with its reason (base#2110)" {
  _scratch_repo
  git checkout -q -b side
  printf 'side\n' > doc/side.md
  _commit side
  git checkout -q main
  printf 'x\n' > script/ci/x.sh
  _commit code
  git checkout -q -b one main
  git -c user.name=t -c user.email=t@t merge -q --no-edit side
  git checkout -q side
  git -c user.name=t -c user.email=t@t merge -q --no-edit main
  git rm -q script/ci/x.sh
  _commit revert
  git branch -q -f main one
  [ "$(git merge-base --all main HEAD | wc -l)" -eq 2 ]
  run bash -c "bash '${SELECTION_SH}' --event pull_request --base main 2>&1"
  _assert_all_selected many_merge_bases
}

# why: base#2110. `ignore = all` in .gitmodules hides a submodule's new
# commit from a plain diff, so the diff must ask for it.
@test "check_selection: a submodule bump hidden by .gitmodules selects every gated job (base#2110)" {
  _scratch_repo
  local _a _b
  _a="$(git rev-parse HEAD)"
  printf '[submodule "s"]\n\tpath = s\n\turl = ./s\n\tignore = all\n' > .gitmodules
  git add .gitmodules
  git update-index --add --cacheinfo "160000,${_a},s"
  git -c user.name=t -c user.email=t@t commit -q -m sub
  _b="$(git rev-parse HEAD)"
  git checkout -q -b case
  printf 'more\n' >> doc/seed.md
  git add doc/seed.md
  git update-index --cacheinfo "160000,${_b},s"
  git -c user.name=t -c user.email=t@t commit -q -m bump
  run _diff_select
  assert_success
  assert_output "$(_expect all)"
}

# why: cycle 20. A deny list that exits non-zero or prints nothing cannot
# say which paths config-gen ignores, so nothing may be dropped.
@test "check_selection: an unreadable deny list selects every gated job (base#1584)" {
  local _d="${BATS_TEST_TMPDIR}/m" _body
  mkdir -p "${_d}"
  cp "${SELECTION_SH}" "${_d}/"
  for _body in 'exit 1' 'exit 0'; do
    printf '%s\n' "${_body}" > "${_d}/config_gen_paths.sh"
    run bash -c "printf 'dist/script/base/init.sh\0' | bash '${_d}/check_selection.sh' --event pull_request --paths 2>&1"
    _assert_all_selected deny_list_unreadable
  done
}

# why: the E1 row. A unit or integration spec is a leaf -- no file under
# test/ or script/ loads or sources a `*_spec.bats` -- so config-gen,
# acceptance and system never execute it; it is code, so coverage and the
# code checks run.
@test "check_selection: a unit spec runs coverage and the code checks only (base#1584)" {
  run _select pull_request test/bats/unit/ci_spec.bats
  assert_success
  assert_output "$(_expect coverage coverage-gate shellcheck hadolint bats-fragile test-tools-image-arm64)"
}

# why: the E1 row for a system spec: system runs the system specs, so it
# and worker-selftest stay; config-gen and acceptance drop.
@test "check_selection: a system spec runs coverage, system and the code checks (base#1584)" {
  run _select pull_request test/bats/system/smoke_spec.bats
  assert_success
  assert_output "$(_expect coverage coverage-gate system worker-selftest shellcheck hadolint bats-fragile test-tools-image-arm64)"
}

# why: every justfile loads with the root one, and a syntax error in one
# module made `just a go` exit 1 in a scratch probe, so any justfile can
# break `just test go`.
@test "check_selection: a justfile anywhere selects every gated job (base#1584)" {
  run _select pull_request script/release/justfile.release
  assert_success
  assert_output "$(_expect all)"
}

# why: the issue's rule: "A change to the map itself, the workflow, the
# test drivers or shared libraries selects every job (fail closed)". None of
# these is a docs path, a spec leaf or a deny entry.
@test "check_selection: the workflow, a driver, the selection files and the unit helper select every gated job (base#1584)" {
  local _p
  for _p in .github/workflows/self-test.yaml script/test/drivers/bats.sh \
            script/ci/check_selection.sh script/ci/config_gen_paths.sh \
            script/ci/config_gen_readers.sh script/ci/selection_at_base.sh \
            test/bats/unit/test_helper.bash; do
    run _select pull_request "${_p}"
    assert_success
    assert_output "$(_expect all)"
  done
}

# why: base#2110. Nothing under doc/ but Markdown is documentation by its
# name alone: a script, a justfile, an image or a page moved there can be
# run or read by code, so it is a path nobody classified.
@test "check_selection: a path under doc/ that is not Markdown selects every gated job (base#2110)" {
  local _p
  for _p in doc/build.sh doc/justfile doc/README doc/badge/coverage.svg \
            doc/arch/overview.html doc/a.md.sh doc/Dockerfile doc/.md/x.sh; do
    run _select pull_request "${_p}"
    assert_success
    assert_output "$(_expect all)"
  done
}

# _diff_select -- the map's answer for the current branch's diff against main.
_diff_select() {
  bash "${SELECTION_SH}" --event pull_request --base main 2>&1
}

# why: base#2110. A name says nothing about the file's mode: a symlink, an
# executable or a submodule named doc/x.md is not documentation, and
# neither is README.md once it becomes a link. The map reads both sides'
# modes with the diff, so a link replaced by a plain file counts too.
@test "check_selection: a documentation name that is a symlink, executable or submodule selects every gated job (base#2110)" {
  _scratch_repo
  local _blob _case _obj
  printf 'r\n' > README.md
  _commit readme
  _blob="$(printf '../script/ci/check_selection.sh' | git hash-object -w --stdin)"
  for _case in '120000 doc/link.md' '120000 README.md' '100755 doc/seed.md' '160000 doc/sub.md'; do
    _obj="${_blob}"
    [[ "${_case}" == 160000* ]] && _obj="$(git rev-parse HEAD)"
    git checkout -q -f -B case main
    git update-index --add --cacheinfo "${_case%% *},${_obj},${_case#* }"
    git -c user.name=t -c user.email=t@t commit -q -m "${_case}"
    run _diff_select
    assert_success
    assert_output "$(_expect all)"
  done
  git checkout -q -f main
  git update-index --add --cacheinfo "120000,${_blob},doc/was-link.md"
  git -c user.name=t -c user.email=t@t commit -q -m link
  git checkout -q -f -B case main
  git update-index --add --cacheinfo "100644,${_blob},doc/was-link.md"
  git -c user.name=t -c user.email=t@t commit -q -m plain
  run _diff_select
  assert_success
  assert_output "$(_expect all)"
}

# why: base#2110. Code cannot be passed off as documentation through the
# shape of the diff: one code line beside a doc edit, a script renamed
# into doc/, and a deleted script each select every job. The control is a
# plain doc edit, addition and deletion, which select none.
@test "check_selection: a doc diff that also changes, moves or deletes code selects every gated job (base#2110)" {
  _scratch_repo
  printf 'old\n' > doc/old.md
  printf 'one\ntwo\nthree\n' > script/ci/tool.sh
  _commit seed
  git checkout -q -b docs
  printf 'more\n' >> doc/seed.md
  printf 'new\n' > doc/new.md
  git rm -q doc/old.md
  _commit docs
  run _diff_select
  assert_success
  assert_output "$(_expect)"

  git checkout -q -B mixed docs
  printf 'x\n' >> script/ci/tool.sh
  _commit mixed
  run _diff_select
  assert_output "$(_expect all)"

  git checkout -q -B moved docs
  git mv script/ci/tool.sh doc/tool.md
  _commit moved
  run _diff_select
  assert_output "$(_expect all)"

  git checkout -q -B deleted docs
  git rm -q script/ci/tool.sh
  _commit deleted
  run _diff_select
  assert_output "$(_expect all)"
}

# why: cycle 28. The base map is run from a scratch directory, so it must
# read nothing but the deny list beside it: a working tree with NO
# selection files still gets the base map's answer.
@test "selection_at_base: a working tree without the map gets the base map's answer (base#1584)" {
  _scratch_repo
  git checkout -q -b pr
  git rm -q -r script/ci/check_selection.sh script/ci/config_gen_paths.sh
  _commit "drop the map and the deny list"
  run bash -c "printf 'doc/x.md\0' | bash '${AT_BASE_SH}' --base main --event pull_request --paths"
  assert_success
  assert_output "$(_expect)"
  run bash -c "printf 'dist/script/base/init.sh\0' | bash '${AT_BASE_SH}' --base main --event pull_request --paths"
  assert_success
  assert_output "$(_expect ${NOT_CONFIG_GEN})"
}

# why: cycle 28, the narrowing half. A working-tree map that drops
# config-gen for everything must not narrow anything: the base map runs.
@test "selection_at_base: a working-tree map cannot narrow the selection (base#1584)" {
  _scratch_repo
  git checkout -q -b pr
  printf '#!/usr/bin/env bash\necho config-gen=false\n' > script/ci/check_selection.sh
  _commit "a map that drops config-gen"
  run bash -c "printf 'zz/x\0' | bash '${AT_BASE_SH}' --base main --event pull_request --paths"
  assert_success
  assert_output "$(_expect all)"
}

# why: selection_at_base.sh's own fail-closed reasons: an empty or bad
# base, and a base that has no map or no deny list (main before this
# change, and any base older than it). The names come from the working
# tree's --jobs.
@test "selection_at_base: a base it cannot judge from selects every gated job with its reason (base#1584)" {
  _scratch_repo
  run bash -c "bash '${AT_BASE_SH}' --base '' --event pull_request --diff 2>&1"
  _assert_all_selected empty_base
  run bash -c "bash '${AT_BASE_SH}' --base no-such-ref --event pull_request --diff 2>&1"
  _assert_all_selected bad_base
  git checkout -q -b old
  git rm -q script/ci/config_gen_paths.sh
  _commit "a base with the map and no deny list"
  git checkout -q -b pr main
  printf 'x\n' > doc/x.md
  _commit pr
  run bash -c "bash '${AT_BASE_SH}' --base old --event pull_request --diff 2>&1"
  _assert_all_selected map_missing_on_base
}

# why: a base map that exits non-zero gave no answer, so nothing may be
# dropped.
@test "selection_at_base: a base map that fails selects every gated job (base#1584)" {
  _scratch_repo
  git checkout -q -b broken
  printf 'exit 3\n' > script/ci/check_selection.sh
  _commit "a failing map"
  git checkout -q -b pr main
  printf 'x\n' > doc/x.md
  _commit pr
  run bash -c "bash '${AT_BASE_SH}' --base broken --event pull_request --diff 2>&1"
  _assert_all_selected base_map_failed
}

# why: cycle 25 (issue item 5). Local and CI reach the map through one
# entry: test.sh --selection and classify's step both call
# selection_at_base.sh, and neither calls check_selection.sh directly.
@test "selection: test.sh and classify reach the map only through selection_at_base.sh (base#1584)" {
  local _step
  _step="$(yaml_step_run /source/.github/workflows/self-test.yaml classify diff)"
  [[ -n "${_step}" ]] || fail "could not read classify's diff step"
  grep -q 'selection_at_base\.sh' <<<"${_step}" || fail "classify does not call selection_at_base.sh"
  if grep -q 'check_selection\.sh' <<<"${_step}"; then
    fail "classify calls check_selection.sh directly"
  fi
  run code_grep -E 'selection_at_base\.sh' /source/script/test/test.sh
  assert_success
  run code_grep -E 'check_selection\.sh' /source/script/test/test.sh
  assert_failure
}

# why: cycle 25. test.sh --selection judges with the named base's map:
# the scratch repo's main holds the real map, so a docs path selects
# nothing and a deny-list path drops config-gen only.
@test "test.sh --selection --base --paths prints the base map's per-job selection (base#1584)" {
  _scratch_repo
  run bash -c "printf '%s\0' doc/x.md | bash /source/script/test/test.sh --selection --base main --paths"
  assert_success
  assert_output "$(_expect)"
  run bash -c "printf '%s\0' dist/script/base/init.sh | bash /source/script/test/test.sh --selection --base main --paths"
  assert_success
  assert_output "$(_expect ${NOT_CONFIG_GEN})"
}

# why: --paths and --base only shape --selection's answer; alone they
# would be silently ignored, so test.sh refuses them.
@test "test.sh --paths or --base without --selection is refused (base#1584)" {
  run bash /source/script/test/test.sh --paths
  assert_failure
  assert_output --partial ci_paths_without_selection
  run bash /source/script/test/test.sh --base main
  assert_failure
  assert_output --partial ci_paths_without_selection
}
