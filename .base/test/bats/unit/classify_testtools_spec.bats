#!/usr/bin/env bats
#
# classify_testtools_spec.bats -- does the classifier know when the
# tooling image is stale?
#
# why: `testtools_changed` tells every image-consuming job whether to
# rebuild the tooling image from source instead of pulling the rolling
# `:main`. On a pull request it is computed from the diff; on every other
# event it was the literal `false`, including the one event that can
# answer it -- a push to main whose commit is what makes `:main` stale in
# the first place. So the merge that added a tool to the Dockerfile ran
# the whole post-merge suite inside the image from before it. The probe
# was supposed to compensate and was itself too narrow to notice; both
# halves are the same incident, and this is the half that can be
# answered from the diff.
#
# The cases drive the REAL classify step against a synthetic push, so
# each reads the output the step writes.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SELF_WF=/source/.github/workflows/self-test.yaml
  assert_spec_subject "${SELF_WF}" \
      "the workflow whose classifier this spec drives"
}

# _classify_event <event> <repo-relative-path> [--root]
#   Runs self-test's OWN classify step against a synthetic history whose
#   head commit changes <path> and nothing else, reported to the step as
#   <event> on CLASSIFY_REF (default refs/heads/main). With `--root` the
#   history is ONE commit, so `HEAD^` does not resolve and the diff cannot
#   be taken at all. Prints the GITHUB_OUTPUT the step wrote.
_classify_event() {
  local _e="${1:?BUG: _classify_event expects an event}"
  local _p="${2:?BUG: _classify_event expects a path}"
  local _root="${3:-}"
  local _d="${BATS_TEST_TMPDIR}/push"
  rm -rf "${_d}"
  mkdir -p "${_d}/$(dirname "${_p}")"
  ln -s /source/script "${_d}/script"
  printf 'a\n' > "${_d}/${_p}"
  git -C "${_d}" init -q -b main
  git -C "${_d}" config user.email ci@example.invalid
  git -C "${_d}" config user.name ci
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m base
  if [[ "${_root}" != "--root" ]]; then
    printf 'b\n' >> "${_d}/${_p}"
    git -C "${_d}" commit -q -a -m change
  fi
  yaml_step_run "${SELF_WF}" classify diff > "${_d}/step.sh"
  [ -s "${_d}/step.sh" ] || return 2
  : > "${_d}/out"
  (
    cd "${_d}" || return 2
    env EVENT_NAME="${_e}" EVENT_REF="${CLASSIFY_REF-refs/heads/main}" BASE_REF= \
        GITHUB_OUTPUT="${_d}/out" bash step.sh
  ) >/dev/null 2>&1
  cat "${_d}/out"
}

# _classify_push <repo-relative-path>
#   The push case of the above, which is the only event that can answer
#   `testtools_changed` from a diff.
_classify_push() {
  _classify_event push "${1:?BUG: _classify_push expects a path}"
}

# _classify_pr <repo-relative-path>
#   The pull-request arm of the same step, which is the arm every PR's
#   image jobs read. The base ref is planted as `refs/remotes/origin/main`
#   because that is the name the step resolves; its own `git fetch` has no
#   remote to reach and is already tolerated by the step's `|| true`.
#
#   The base commit holds a real copy of /source/script, not a link to it:
#   base#1584 judges a PR with the map read from the BASE side through
#   `git show <base>:script/ci/...`, and git cannot read a file through a
#   committed symlink (`git show HEAD:script/ci/a.sh` exits 128 when
#   `script` is a link). dist/ and dockerfile/ are copied beside it because
#   script/ci/testtools_paths.sh reads them relative to its own location
#   (`../../dist/script/docker/lib/project_reclaim.sh` and the Dockerfile),
#   which the link used to resolve into /source.
#
#   <path> `-` changes no plain file. CLASSIFY_BASE_HOOK and
#   CLASSIFY_PR_HOOK, when set, name a function run in the repo before the
#   base commit and before the PR commit, so a case can plant files on
#   either side. The step's stderr is left in ${BATS_TEST_TMPDIR}/step.err.
_classify_pr() {
  local _p="${1:?BUG: _classify_pr expects a path or -}"
  local _d="${BATS_TEST_TMPDIR}/pr" _t
  # A directory the Dockerfile COPYs (base#1847) is changed through a file
  # inside it: git sees files, and the directory already exists in the copy.
  [[ "${_p}" != - && -d "/source/${_p}" ]] && _p="${_p%/}/classify-probe.txt"
  rm -rf "${_d}"
  mkdir -p "${_d}"
  for _t in script dist dockerfile; do
    cp -a "/source/${_t}" "${_d}/${_t}"
  done
  mkdir -p "${_d}/doc"
  printf 'seed\n' > "${_d}/doc/seed.md"
  if [[ "${_p}" != - ]]; then
    mkdir -p "${_d}/$(dirname "${_p}")"
    printf 'a\n' > "${_d}/${_p}"
  fi
  git -C "${_d}" init -q -b main
  git -C "${_d}" config user.email ci@example.invalid
  git -C "${_d}" config user.name ci
  if [[ -n "${CLASSIFY_BASE_HOOK:-}" ]]; then
    (cd "${_d}" && "${CLASSIFY_BASE_HOOK}") || return 2
  fi
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m base
  git -C "${_d}" update-ref refs/remotes/origin/main HEAD
  [[ "${_p}" == - ]] || printf 'b\n' >> "${_d}/${_p}"
  if [[ -n "${CLASSIFY_PR_HOOK:-}" ]]; then
    (cd "${_d}" && "${CLASSIFY_PR_HOOK}") || return 2
  fi
  git -C "${_d}" add -A
  git -C "${_d}" commit -q -m change
  yaml_step_run "${SELF_WF}" classify diff > "${BATS_TEST_TMPDIR}/step.sh"
  [ -s "${BATS_TEST_TMPDIR}/step.sh" ] || return 2
  : > "${BATS_TEST_TMPDIR}/out"
  (
    cd "${_d}" || return 2
    env EVENT_NAME=pull_request EVENT_REF=refs/pull/1/merge BASE_REF=main \
        IS_FORK_PR="${CLASSIFY_IS_FORK-false}" \
        DEFAULT_BRANCH="${CLASSIFY_DEFAULT_BRANCH-main}" \
        GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" bash "${BATS_TEST_TMPDIR}/step.sh"
  ) >/dev/null 2>"${BATS_TEST_TMPDIR}/step.err"
  cat "${BATS_TEST_TMPDIR}/out"
}

# _context_copy_paths
#   Every build-context path the tooling Dockerfile COPYs, read off the
#   DOCKERFILE through the shared reader rather than through the signal
#   under test: a population computed by the subject would certify the
#   subject against itself.
#
#   Filtered to paths that exist in this checkout, because each one is
#   driven by committing a change to it. The shapes the reader cannot
#   resolve -- a glob, a variable, a line continuation -- are the
#   derivation's own business and are asserted where it lives, in
#   testtools_paths_spec.bats.
_context_copy_paths() {
  local _p
  dockerfile_context_copy_srcs /source/dockerfile/Dockerfile.test-tools \
    | while IFS= read -r _p; do
        [[ -n "${_p}" && -e "/source/${_p}" ]] && printf '%s\n' "${_p}"
      done
}

# why: The reported case. A push to main that changes the test-tools
# Dockerfile is exactly the push for which the rolling tag is stale --
# the republish that would refresh it is racing this very run -- and it
# was the push that reported the image unchanged.
@test "classify: a push that changes the test-tools Dockerfile rebuilds it (#1010)" {
  run _classify_push dockerfile/Dockerfile.test-tools
  assert_success
  assert_line 'testtools_changed=true'
}

# why: The guard against answering true to every push, which would put a
# full multi-arch tooling build in front of every merge. A push that
# leaves the Dockerfile alone takes the pull path, where the probe is now
# the thing that catches a stale image.
@test "classify: a push that leaves it alone still pulls (#1010)" {
  run _classify_push doc/guide.md
  assert_success
  assert_line 'testtools_changed=false'
}

# why: the flag being computable must not narrow what a push runs.
@test "classify: a push is still code-changed and system-relevant (#1010)" {
  run _classify_push doc/guide.md
  assert_success
  assert_line 'code_changed=true'
  assert_line 'system_relevant=true'
}

# why: The fail-safe direction the step's own comment promises and did not
# take. `workflow_dispatch` has no previous commit to diff against, so the
# classifier cannot know whether the rolling tag corresponds to this ref --
# and it answered `false`, which is the side that USES an image it could
# not check. The path here is deliberately not the Dockerfile, so a `true`
# can only come from the default and never from a diff.
@test "classify: an event that cannot be diffed still rebuilds (#1010)" {
  run _classify_event workflow_dispatch doc/guide.md
  assert_success
  assert_line 'testtools_changed=true'
}

# why: The other half of the same promise, and the half that already held:
# a push whose `HEAD^` does not resolve is a diff that cannot be taken, not
# an answer of "unchanged". Pinned because the fix above rewrites the
# branch that decides it, and a rewrite that inverted this one would look
# green against the dispatch case alone.
@test "classify: a push with no parent to diff still rebuilds (#1010)" {
  run _classify_event push doc/guide.md --root
  assert_success
  assert_line 'testtools_changed=true'
}

# ── the inputs that are not the Dockerfile ────────────────────────────

# why: The defect this spec was extended for. The signal named one path,
# and the tooling image has more inputs than that: a plain build-context
# COPY bakes a file of the checkout into the image, so editing that file
# alone leaves a `:main` that no longer describes the tree while the
# classifier reports the image unchanged. The population is read off the
# Dockerfile, so the next COPY anyone adds brings its own case with it
# instead of waiting for someone to remember this list.
@test "classify: a push that changes a file the Dockerfile COPYs rebuilds it (#1171)" {
  local _p _missed=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    run _classify_push "${_p}"
    assert_success
    grep -qx 'testtools_changed=true' <<< "${output}" \
      || _missed="${_missed}${_p}"$'\n'
  done < <(_context_copy_paths)
  [[ -z "${_missed}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context, and a push that changes one reports the image unchanged:"$'\n'"${_missed}"
}

# why: The same miss on the arm every pull request takes, which is the
# expensive one: the PR arm's `false` sends `obtain_test_tools.sh` down its
# layer-2 path, so the whole suite runs inside the rolling `:main` -- an
# image built before the edit, and one nothing on the PR path refreshes.
@test "classify: a PR that changes a file the Dockerfile COPYs rebuilds it (#1171)" {
  local _p _missed=""
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] || continue
    run _classify_pr "${_p}"
    assert_success
    grep -qx 'testtools_changed=true' <<< "${output}" \
      || _missed="${_missed}${_p}"$'\n'
  done < <(_context_copy_paths)
  [[ -z "${_missed}" ]] || fail \
      "the tooling Dockerfile COPYs these paths out of the build context, and a PR that changes one runs inside the stale rolling tag:"$'\n'"${_missed}"
}

# why: The guard that keeps the two cases above from being bought by
# answering `true` to everything. "Anything changed" would rebuild the
# tooling image on every pull request and throw away the pull path the
# rolling tag exists for.
@test "classify: a PR that changes nothing the image reads still pulls (#1171)" {
  run _classify_pr doc/guide.md
  assert_success
  assert_line 'testtools_changed=false'
}

# why: The Dockerfile's own case on the PR arm, pinned alongside the two
# above so a rewrite that reaches for the derivation cannot drop the one
# input the signal already had.
@test "classify: a PR that changes the test-tools Dockerfile rebuilds it (#1171)" {
  run _classify_pr dockerfile/Dockerfile.test-tools
  assert_success
  assert_line 'testtools_changed=true'
}

# The select_* keys classify writes, one per gated job; config-gen-gates
# reads select_config_gen.
SELECT_KEYS="select_config_gen select_config_gen_redpath select_coverage select_coverage_gate select_acceptance select_system select_worker_selftest select_shellcheck select_hadolint select_bats_fragile select_mutation_roster select_test_tools_image_arm64"
# The release-only ones of those: the event decides them, not the diff.
RELEASE_KEYS="select_mutation_roster select_config_gen_redpath"

# _assert_keys <output> <value> [<key>...] -- every select_* key named (all
# of them when none is) is exactly <value> in <output>.
_assert_keys() {
  local _out="$1" _v="$2" _k _bad=""
  shift 2
  local _keys="${*:-${SELECT_KEYS}}"
  for _k in ${_keys}; do
    grep -qx "${_k}=${_v}" <<< "${_out}" || _bad+=" ${_k}"
  done
  [[ -z "${_bad}" ]] || fail "not ${_v}:${_bad}"$'\n'"output:"$'\n'"${_out}"
}

# _assert_all_but_release <output> -- every select_* key is `true` in
# <output> except the release-only ones, which are `false`.
_assert_all_but_release() {
  local _k _rest=""
  for _k in ${SELECT_KEYS}; do
    [[ " ${RELEASE_KEYS} " == *" ${_k} "* ]] || _rest+=" ${_k}"
  done
  _assert_keys "$1" true ${_rest}
  _assert_keys "$1" false ${RELEASE_KEYS}
}

# The ref a merge_group run is for, in the form GitHub names it.
MERGE_GROUP_REF=refs/heads/gh-readonly-queue/main/pr-1-0123456789abcdef0123456789abcdef01234567

# why: a push is not narrowed by its diff; only the jobs that wait for a tag
# skip on it.
@test "classify: a push to main or master selects every gated job but the release-only ones (base#1584, base#2177)" {
  run _classify_push doc/guide.md
  assert_success
  _assert_all_but_release "${output}"
  CLASSIFY_REF=refs/heads/master run _classify_push doc/guide.md
  assert_success
  _assert_all_but_release "${output}"
}

# why: a merge group is the last run before main, so even a docs-only one is
# not narrowed, or the queue would land a commit its gated jobs never ran on.
@test "classify: a merge_group run selects every gated job but the release-only ones (base#1584, base#1587, base#2177)" {
  CLASSIFY_REF="${MERGE_GROUP_REF}" run _classify_event merge_group doc/guide.md
  assert_success
  _assert_all_but_release "${output}"
}

# why: the tag's `release` job needs the release-only jobs, and
# workflow_dispatch gives their answer before the tag exists.
@test "classify: a tag push and workflow_dispatch select every gated job, the release-only ones included (base#2177)" {
  CLASSIFY_REF=refs/tags/v1.2.3 run _classify_push doc/guide.md
  assert_success
  _assert_keys "${output}" true
  run _classify_event workflow_dispatch doc/guide.md
  assert_success
  _assert_keys "${output}" true
}

# why: fail closed: a trigger or a kind of ref added later runs the
# release-only jobs until the step names it, and cannot drop them by omission.
@test "classify: a push to no known branch, or an event the step does not name, selects the release-only jobs (base#2177)" {
  local _ref
  for _ref in '' refs/notes/x main; do
    CLASSIFY_REF="${_ref}" run _classify_push doc/guide.md
    assert_success
    _assert_keys "${output}" true
  done
  run _classify_event schedule doc/guide.md
  assert_success
  _assert_keys "${output}" true
}

# why: any other binding makes a tag push read as a branch, or a branch push
# as a tag.
@test "classify: the diff step reads the run's own ref (base#2177)" {
  run yq '.jobs.classify.steps[] | select(.id == "diff") | .env.EVENT_REF' "${SELF_WF}"
  assert_output "\${{ github.ref }}"
}

# why: with a key of its own the event can skip the roster and nothing else,
# and no job joins or leaves the workflow without this list changing.
@test "self-test.yaml: mutation-roster is gated on its own key and the job list is main's (base#1584, base#2110)" {
  run yq '.jobs."mutation-roster".if' "${SELF_WF}"
  assert_output "needs.classify.outputs.select_mutation_roster == 'true'"
  run yaml_job_names "${SELF_WF}"
  assert_output "actionlint
classify
test-tools-image-amd64
test-tools-image-arm64
shellcheck
doc-counts
lint-static
single-issue-pr
mutation-roster
hadolint
bats-fragile
compute-shards
coverage
coverage-gate
acceptance
system
worker-selftest
config-gen-gates
config-gen-redpath
commit-attribution
ci-rollup
release"
}

# why: fail closed: a path the map does not know skips no job the map
# decides. `zz-new/thing.txt` names no directory the repo has.
@test "classify: a pull request touching an unknown path selects every gated job but the release-only ones (base#1584, base#2177)" {
  run _classify_pr zz-new/thing.txt
  assert_success
  _assert_all_but_release "${output}"
}

# why: cycle 21 (RR3-F1). A docs path selects nothing: the map's doc row is
# the code_changed allow-list (doc/**, README.md, LICENSE, CONTEXT.md). The
# base commit holds a real copy of /source/script, so the real map and
# deny list are read from the base through `git show`. Each value is
# exact: a classify that never carries a `false` through fails here.
@test "classify: a docs-only pull request writes every gated job's selection as false (base#1584)" {
  run _classify_pr doc/x.md
  assert_success
  assert_line 'select_config_gen=false'
  assert_line 'select_acceptance=false'
  assert_line 'select_coverage=false'
  assert_line 'select_system=false'
  assert_line 'select_shellcheck=false'
  _assert_keys "${output}" false
}

# why: cycle 22 (RR3-F1). A unit spec is a leaf (row E1): coverage and the
# code checks run; config-gen, acceptance, system and worker-selftest do
# not.
@test "classify: a pull request changing one unit spec selects coverage and the code checks only (base#1584)" {
  run _classify_pr test/bats/unit/ci_spec.bats
  assert_success
  assert_line 'select_config_gen=false'
  assert_line 'select_acceptance=false'
  assert_line 'select_system=false'
  assert_line 'select_worker_selftest=false'
  assert_line 'select_mutation_roster=false'
  assert_line 'select_config_gen_redpath=false'
  assert_line 'select_coverage=true'
  _assert_keys "${output}" true select_coverage_gate select_shellcheck \
      select_hadolint select_bats_fragile select_test_tools_image_arm64
}

# why: a diff narrows only a run known to be same-repo; any other is still a
# pull request, so the release-only jobs skip on it.
@test "classify: a fork pull request, or one not known to be same-repo, selects every gated job (base#2110)" {
  local _v
  for _v in true ''; do
    CLASSIFY_IS_FORK="${_v}" run _classify_pr doc/x.md
    assert_success
    _assert_all_but_release "${output}"
  done
  run yq '.jobs.classify.steps[] | select(.id == "diff") | .env.IS_FORK_PR' "${SELF_WF}"
  assert_output "\${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}"
}

# why: base#2110. A pull request into any other branch can be retargeted at
# the default branch without a new run, so its diff against the other branch
# would stand for the one that merges. Only a pull request into the default
# branch is narrowed, and not knowing is not being one. A branch whose name
# differs only in case is another branch (GitHub's own == ignores case).
@test "classify: a pull request not known to target the default branch selects every gated job (base#2110)" {
  local _v
  for _v in other Main ''; do
    CLASSIFY_DEFAULT_BRANCH="${_v}" run _classify_pr doc/x.md
    assert_success
    _assert_all_but_release "${output}"
  done
  run yq '.jobs.classify.steps[] | select(.id == "diff") | .env.DEFAULT_BRANCH' "${SELF_WF}"
  assert_output "\${{ github.event.repository.default_branch }}"
}

# _pr_shadows_base_with_a_tag -- the PR side changes code, and a tag named
# like the base's remote branch points at that code.
_pr_shadows_base_with_a_tag() {
  printf 'x\n' > zz-code.sh
  git add zz-code.sh
  git commit -q -m code
  git tag origin/main
}

# why: base#2110. `origin/main` as a bare name resolves to a tag of that name
# before the remote branch, so a pushed tag could stand in for the base. The
# step names the remote branch in full.
@test "classify: a tag named like the base branch does not stand in for it (base#2110)" {
  CLASSIFY_PR_HOOK=_pr_shadows_base_with_a_tag run _classify_pr doc/x.md
  assert_success
  _assert_all_but_release "${output}"
}

# _pr_edits_selection_at_base -- the PR side's selection_at_base.sh answers
# `false` for every job.
_pr_edits_selection_at_base() {
  printf '%s\n' 'for j in $(bash script/ci/check_selection.sh --jobs); do echo "$j=false"; done' \
    > script/ci/selection_at_base.sh
}

# why: base#2110. The script that runs the base side's map is read from the
# base too: one read from the pull request could answer without the map.
@test "classify: a pull request's own selection_at_base.sh does not judge it (base#2110)" {
  CLASSIFY_PR_HOOK=_pr_edits_selection_at_base run _classify_pr doc/x.md
  assert_success
  _assert_all_but_release "${output}"
}

# _base_map_fails -- the base side's map exits 1.
_base_map_fails() {
  printf 'exit 1\n' > script/ci/check_selection.sh
}

# _base_map_drops_acceptance -- the base side's map leaves out its
# acceptance line.
_base_map_drops_acceptance() {
  sed -i 's/^main "\$@"$/main "$@" | grep -v "^acceptance="/' script/ci/check_selection.sh
  grep -q 'grep -v "^acceptance="' script/ci/check_selection.sh
}

# why: cycle 23. A selection that exits non-zero gave no answer, and a
# line the selection leaves out is no `false`: classify writes `true` for
# both, and keeps the map's own values for every line it did print.
@test "classify: a base map that fails or leaves a job out selects it (base#1584)" {
  CLASSIFY_BASE_HOOK=_base_map_fails run _classify_pr doc/x.md
  assert_success
  _assert_all_but_release "${output}"
  grep -q 'reason=base_map_failed' "${BATS_TEST_TMPDIR}/step.err" \
    || fail "stderr: $(cat "${BATS_TEST_TMPDIR}/step.err")"
  CLASSIFY_BASE_HOOK=_base_map_drops_acceptance run _classify_pr doc/x.md
  assert_success
  assert_line 'select_acceptance=true'
  _assert_keys "${output}" false select_config_gen select_coverage \
      select_coverage_gate select_system select_worker_selftest \
      select_shellcheck select_hadolint select_bats_fragile \
      select_mutation_roster select_config_gen_redpath \
      select_test_tools_image_arm64
}

# _pr_map_selects_nothing_for_row5 -- the PR side's map: row 5 (`*`)
# selects nothing (RR6-F1's mutant), which also changes the map itself.
_pr_map_selects_nothing_for_row5() {
  sed -i 's/^    \*) _cs_select "\${_CS_KEYS\[@\]}" ;;$/    *) : ;;/' script/ci/check_selection.sh
  grep -q '^    \*) : ;;$' script/ci/check_selection.sh
}

# _pr_deny_list_adds_the_map -- the PR side's deny list names the map.
_pr_deny_list_adds_the_map() {
  sed -i 's|^PATHS$|script/ci/check_selection.sh\nPATHS|' script/ci/config_gen_paths.sh
  grep -qx 'script/ci/check_selection.sh' script/ci/config_gen_paths.sh
}

# _pr_edits_the_readers -- the PR side changes only the readers script.
_pr_edits_the_readers() {
  printf '# edited\n' >> script/ci/config_gen_readers.sh
}

# why: cycle 26 (RR6-F1). A PR is judged by the BASE side's map, never its
# own: a PR whose map selects nothing for an unknown path, and which
# changes that map, would otherwise classify itself with it and skip every
# job (RR6-F1's probe printed all five false). Each selection file a PR
# edits is an unknown path to the base map, so every job runs.
@test "classify: a pull request that edits a selection file is judged by the base map (base#1584)" {
  CLASSIFY_PR_HOOK=_pr_map_selects_nothing_for_row5 run _classify_pr doc/x.md
  assert_success
  _assert_all_but_release "${output}"
  CLASSIFY_PR_HOOK=_pr_deny_list_adds_the_map run _classify_pr -
  assert_success
  _assert_all_but_release "${output}"
  CLASSIFY_PR_HOOK=_pr_edits_the_readers run _classify_pr -
  assert_success
  _assert_all_but_release "${output}"
}

# _base_without_map -- the base predates the map (main before base#1584);
# the PR side restores the real files.
_base_without_map() { rm -f script/ci/check_selection.sh; }
_base_without_deny_list() { rm -f script/ci/config_gen_paths.sh; }
_pr_restores_selection() {
  cp /source/script/ci/check_selection.sh /source/script/ci/config_gen_paths.sh script/ci/
}

# why: cycle 27, the bootstrap. A base with no map or no deny list (main
# when this change lands, and any older base) cannot judge the PR, so
# every job runs, naming map_missing_on_base.
@test "classify: a base without the map or its deny list selects every gated job (base#1584)" {
  local _hook
  for _hook in _base_without_map _base_without_deny_list; do
    CLASSIFY_BASE_HOOK="${_hook}" CLASSIFY_PR_HOOK=_pr_restores_selection \
      run _classify_pr doc/x.md
    assert_success
    _assert_all_but_release "${output}"
    grep -q 'reason=map_missing_on_base' "${BATS_TEST_TMPDIR}/step.err" \
      || fail "${_hook}: stderr: $(cat "${BATS_TEST_TMPDIR}/step.err")"
  done
}

# why: the step must not invent a `false` for a job the map decides: it has
# one selection call, and passes on only the `false` it read there.
@test "classify: the diff step's only select_* false is the selection's own or a release-only job's (base#1584, base#2177)" {
  local _step
  _step="$(yaml_step_run "${SELF_WF}" classify diff | grep -v '^[[:space:]]*#')"
  [[ -n "${_step}" ]] || fail "could not read classify's diff step"
  run grep -c 'selection_at_base\.sh' <<< "${_step}"
  assert_output 1
  run grep -E 'check_selection\.sh' <<< "${_step}"
  assert_failure
  run grep -E 'select_[a-z_${}/-]*=false' <<< "${_step}"
  assert_failure
  local _lines
  _lines="$(grep -E '\bval\b.*false|false.*\bval\b' <<< "${_step}" | sed 's/^[[:space:]]*//')"
  assert_equal "${_lines}" '[[ "${val}" == "false" ]] || val=true'
}

# _chain_classify_outputs <classify-output> <assoc-name>
#   Fills the associative array named <assoc-name> with classify's job
#   outputs as GitHub resolves them: each key of the classify job's
#   `outputs:` map gets the last value the diff step wrote for the
#   `steps.diff.outputs.<k>` it names in <classify-output> (GITHUB_OUTPUT
#   lines), and an output bound any other way, or never written, is empty.
_chain_classify_outputs() {
  local _step_out="${1}" _k _v
  local -n _into="${2}"
  while read -r _k _v; do
    [[ -n "${_k}" ]] || continue
    _into["${_k}"]=""
    if [[ "${_v}" =~ ^\$\{\{\ steps\.diff\.outputs\.([a-z0-9_]+)\ \}\}$ ]]; then
      _into["${_k}"]="$(sed -n "s/^${BASH_REMATCH[1]}=//p" <<< "${_step_out}" | tail -n 1)"
    fi
  done < <(yq '.jobs.classify.outputs | to_entries[] | .key + " " + .value' "${SELF_WF}")
}

# _chain_results <classify-output>
#   Prints `<job> <success|failure|skipped>` for every job of the workflow,
#   in file order, for a run on CHAIN_REF (unset: a ref that is no tag)
#   whose classify diff step wrote <classify-output> (GITHUB_OUTPUT lines)
#   and in which every job that runs succeeds, but CHAIN_FAIL, which fails.
#   Composes the step's output through the classify job's own
#   `outputs:` map and each job's parsed `if:`, so a key the step writes but
#   the job does not export reads empty, as it does on GitHub. A job runs
#   when its `if:` holds and every job it needs succeeded (the implicit
#   `success() &&` of a job-level `if:`); `always()` runs it whatever its
#   needs did. Any other `if:` shape returns 2, so a gate this reader cannot
#   evaluate fails the case instead of being guessed.
_chain_results() {
  local _j _if _n _ok
  local -A _cls=() _res=()
  _chain_classify_outputs "${1}" _cls
  while IFS= read -r _j; do
    [[ -n "${_j}" ]] || continue
    _if="$(LP_J="${_j}" yq '.jobs[strenv(LP_J)].if // ""' "${SELF_WF}")"
    _ok=1
    while IFS= read -r _n; do
      [[ -n "${_n}" ]] || continue
      [[ -n "${_res[${_n}]:-}" ]] || { echo "BUG: ${_j} needs ${_n}, which comes later"; return 2; }
      [[ "${_res[${_n}]}" == "success" ]] || _ok=0
    done < <(LP_J="${_j}" yq '.jobs[strenv(LP_J)].needs // [] | (select(tag == "!!seq") | .[]), select(tag == "!!str")' "${SELF_WF}")
    if [[ "${_j}" == "classify" ]]; then
      _ok=1
    elif [[ -z "${_if}" ]]; then
      :
    elif [[ "${_if}" =~ ^needs\.classify\.outputs\.([a-z0-9_]+)\ ==\ \'true\'$ ]]; then
      [[ "${_cls[${BASH_REMATCH[1]}]:-}" == "true" ]] || _ok=0
    elif [[ "${_if}" == "always()" ]]; then
      _ok=1
    elif [[ "${_if}" == "startsWith(github.ref, 'refs/tags/')" ]]; then
      [[ "${CHAIN_REF:-}" == refs/tags/* ]] || _ok=0
    else
      echo "BUG: ${_j} has an if: this reader cannot evaluate: ${_if}"
      return 2
    fi
    if [[ "${_ok}" -eq 0 ]]; then
      _res["${_j}"]=skipped
    elif [[ "${_j}" == "${CHAIN_FAIL:-}" ]]; then
      _res["${_j}"]=failure
    else
      _res["${_j}"]=success
    fi
    printf '%s %s\n' "${_j}" "${_res[${_j}]}"
  done < <(yaml_job_names "${SELF_WF}")
}

# _chain_rollup <classify-output> <chain-results>
#   Runs ci-rollup's OWN `Verify upstream jobs` step, lifted from the YAML,
#   with every env key bound from the expression it declares: a
#   `needs.<job>.result` from <chain-results>, a `needs.classify.outputs.<k>`
#   through classify's `outputs:` map from <classify-output>, `toJSON(needs)`
#   as the JSON of the same two, and IS_FORK_PR as a same-repo PR. A key
#   bound any other way returns 2.
_chain_rollup() {
  local _results="${2}" _k _v _j _r _json="" _o
  local -A _cls=() _res=()
  local -a _env=()
  _chain_classify_outputs "${1}" _cls
  while read -r _j _r; do
    [[ -n "${_j}" ]] && _res["${_j}"]="${_r}"
  done <<< "${_results}"
  while IFS= read -r _j; do
    [[ -n "${_j}" ]] || continue
    _o="{}"
    if [[ "${_j}" == "classify" ]]; then
      _o=""
      for _k in "${!_cls[@]}"; do
        _o+="${_o:+,}\"${_k}\":\"${_cls[${_k}]}\""
      done
      _o="{${_o}}"
    fi
    _json+="${_json:+,}\"${_j}\":{\"result\":\"${_res[${_j}]:-}\",\"outputs\":${_o}}"
  done < <(yq '.jobs."ci-rollup".needs[]' "${SELF_WF}")
  _json="{${_json}}"
  while read -r _k _v; do
    [[ -n "${_k}" ]] || continue
    if [[ "${_k}" == "IS_FORK_PR" ]]; then
      _env+=("IS_FORK_PR=false")
    elif [[ "${_v}" =~ ^\$\{\{\ needs\.([a-z-]+)\.result\ \}\}$ ]]; then
      _env+=("${_k}=${_res[${BASH_REMATCH[1]}]:-}")
    elif [[ "${_v}" =~ ^\$\{\{\ needs\.classify\.outputs\.([a-z0-9_]+)\ \}\}$ ]]; then
      _env+=("${_k}=${_cls[${BASH_REMATCH[1]}]:-}")
    elif [[ "${_v}" =~ ^\$\{\{\ toJSON\(needs\)\ \}\}$ ]]; then
      _env+=("${_k}=${_json}")
    else
      echo "BUG: rollup env ${_k} is bound in a way this reader does not know: ${_v}"
      return 2
    fi
  done < <(yq '.jobs."ci-rollup".steps[]
      | select(.name == "Verify upstream jobs") | .env | to_entries[]
      | .key + " " + .value' "${SELF_WF}")
  yaml_step_run "${SELF_WF}" ci-rollup 'Verify upstream jobs' \
      > "${BATS_TEST_TMPDIR}/chain-rollup.sh"
  [ -s "${BATS_TEST_TMPDIR}/chain-rollup.sh" ] || return 2
  env "${_env[@]}" bash "${BATS_TEST_TMPDIR}/chain-rollup.sh"
}

# _chain_check <results> <job=result>... -- every named job got that result.
_chain_check() {
  local _results="$1" _want _j _got _bad=""
  shift
  for _want in "$@"; do
    _j="${_want%%=*}"
    _got="$(awk -v j="${_j}" '$1 == j {print $2}' <<< "${_results}")"
    [[ "${_got}" == "${_want#*=}" ]] || _bad+="${_j}: want ${_want#*=}, got ${_got:-<none>}"$'\n'
  done
  [[ -z "${_bad}" ]] || fail "the run set differs:
${_bad}"
}

# _gated_jobs -- the jobs whose parsed `if:` is neither `always()` nor a
# tag test: the jobs a classify output gates.
_gated_jobs() {
  yq '.jobs | to_entries[] | select((.value.if // "") != ""
        and .value.if != "always()"
        and (.value.if | test("^startsWith") | not)) | .key' "${SELF_WF}"
}

# why: cycle 1, end to end on a PR that changes one unit spec. The expected
# set comes from the issue and the design, not from the map: a unit spec
# cannot affect config-gen, acceptance, system or worker-selftest, so
# those skip; it is code, so shellcheck, hadolint, bats-fragile,
# coverage and coverage-gate run; and the release-only jobs skip.
# Read through classify's real step, its `outputs:` map, every
# job's parsed `if:` and the real rollup step, so a gate that reads the
# wrong output, an output classify does not export, or a classify that
# never carries a `false` all change the set, and the rollup must pass
# the run that results.
@test "chain: a PR changing one unit spec runs the code checks, skips the other gated jobs, and the rollup passes (base#1584, base#2177)" {
  local _out _results
  _out="$(_classify_pr test/bats/unit/ci_spec.bats)"
  run _chain_results "${_out}"
  assert_success
  _results="${output}"
  _chain_check "${_results}" shellcheck=success hadolint=success \
      bats-fragile=success coverage=success coverage-gate=success \
      mutation-roster=skipped config-gen-gates=skipped \
      config-gen-redpath=skipped acceptance=skipped \
      system=skipped worker-selftest=skipped
  run _chain_rollup "${_out}" "${_results}"
  assert_success
}

# why: a docs-only PR can affect no gated job; the documentation checks still
# run, and the rollup says which kind of pass it is.
@test "chain: a docs-only PR skips every gated job, mutation-roster included, and the rollup passes as doc-only (base#1584, base#2110)" {
  local _out _results _j
  local -a _want=(mutation-roster=skipped test-tools-image-arm64=skipped
    doc-counts=success lint-static=success single-issue-pr=success
    commit-attribution=success)
  _out="$(_classify_pr doc/x.md)"
  run _chain_results "${_out}"
  assert_success
  _results="${output}"
  while IFS= read -r _j; do
    [[ -n "${_j}" ]] && _want+=("${_j}=skipped")
  done < <(_gated_jobs)
  [[ "${#_want[@]}" -eq 18 ]] || fail "expected twelve gated jobs, read $(( ${#_want[@]} - 6 ))"
  _chain_check "${_results}" "${_want[@]}"
  run _chain_rollup "${_out}" "${_results}"
  assert_success
  assert_output --partial 'Passed as a doc-only change'
}

# The release-only jobs, by job name.
RELEASE_JOBS="mutation-roster config-gen-redpath"

# _chain_gated <results> <release-only-result> -- every gated job got
# `success`, but the release-only ones, which got <release-only-result>.
_chain_gated() {
  local _results="$1" _rel="$2" _j
  local -a _want=()
  while IFS= read -r _j; do
    [[ -n "${_j}" ]] || continue
    if [[ " ${RELEASE_JOBS} " == *" ${_j} "* ]]; then
      _want+=("${_j}=${_rel}")
    else
      _want+=("${_j}=success")
    fi
  done < <(_gated_jobs)
  [[ "${#_want[@]}" -eq 12 ]] || fail "expected twelve gated jobs, read ${#_want[@]}"
  _chain_check "${_results}" "${_want[@]}"
}

# why: a workflow change, a driver change and an unknown path can each break
# any job, so only the jobs that wait for a release skip.
@test "chain: a workflow, driver or unknown-path PR skips no gated job but the release-only ones (base#1584, base#2177)" {
  local _p _out
  for _p in .github/workflows/self-test.yaml script/test/drivers/bats.sh zz-new/thing.txt; do
    _out="$(_classify_pr "${_p}")"
    run _chain_results "${_out}"
    assert_success
    _chain_gated "${output}" skipped
  done
}

# why: branch protection requires the rollup, so the skips must pass it; and
# it must name the jobs, so that its green is not read as a full run's.
@test "chain: a PR, a merge group and a push to main skip the release-only jobs, and the rollup passes naming them (base#2176, base#2177)" {
  local _run _out _results
  for _run in pull_request merge_group push; do
    case "${_run}" in
      pull_request) _out="$(_classify_pr zz-new/thing.txt)" ;;
      merge_group) _out="$(CLASSIFY_REF="${MERGE_GROUP_REF}" _classify_event merge_group zz-new/thing.txt)" ;;
      push) _out="$(_classify_push zz-new/thing.txt)" ;;
    esac
    run _chain_results "${_out}"
    assert_success
    _results="${output}"
    _chain_gated "${_results}" skipped
    _chain_check "${_results}" release=skipped
    run _chain_rollup "${_out}" "${_results}"
    assert_success
    assert_line '::notice::Passed with jobs classify deselected for this run, skipped by design: mutation-roster config-gen-redpath'
  done
}

# _chain_config_gen <classify-output> <gates-result> -- config-gen-gates got
# <gates-result> and config-gen-redpath skipped, and the rollup passes.
_chain_config_gen() {
  local _results
  _results="$(_chain_results "$1")"
  _chain_check "${_results}" "config-gen-gates=$2" config-gen-redpath=skipped
  run _chain_rollup "$1" "${_results}"
  assert_success
}

# why: the two config-gen keys must not be crossed, or skipping the redpath
# would skip the gates too, or the gates' selection would run the redpath.
@test "chain: config-gen-gates keeps its own selection where the redpath skips (base#2176)" {
  _chain_config_gen "$(_classify_pr dockerfile/config-gen/cmd/config-gen/main.go)" success
  _chain_config_gen "$(_classify_pr script/test/config_gen_redpath.sh)" success
  _chain_config_gen "$(_classify_pr dist/env.toml)" skipped
  _chain_config_gen "$(CLASSIFY_REF="${MERGE_GROUP_REF}" _classify_event merge_group doc/x.md)" success
  _chain_config_gen "$(_classify_push doc/x.md)" success
}

# why: the tag is where the release-only jobs block, and a dispatch on a branch
# is how they are checked before the tag exists, with nothing published.
@test "chain: a tag push and workflow_dispatch run the release-only jobs, and only the tag releases (base#2176, base#2177)" {
  local _out
  _out="$(CLASSIFY_REF=refs/tags/v1.2.3 _classify_push zz-new/thing.txt)"
  CHAIN_REF=refs/tags/v1.2.3 run _chain_results "${_out}"
  assert_success
  _chain_gated "${output}" success
  _chain_check "${output}" release=success
  run _chain_rollup "${_out}" "${output}"
  assert_success
  refute_output --partial 'skipped by design'

  _out="$(_classify_event workflow_dispatch zz-new/thing.txt)"
  CHAIN_REF=refs/heads/main run _chain_results "${_out}"
  assert_success
  _chain_gated "${output}" success
  _chain_check "${output}" release=skipped
  run _chain_rollup "${_out}" "${output}"
  assert_success
  refute_output --partial 'skipped by design'
}

# why: the rollup excuses a job classify deselected, so `release` cannot rest
# on the rollup: it must need each release-only job itself.
@test "chain: a tag on which a release-only job fails or never runs publishes no release (base#2176, base#2177)" {
  local _out _j
  _out="$(CLASSIFY_REF=refs/tags/v1.2.3 _classify_push zz-new/thing.txt)"
  for _j in ${RELEASE_JOBS}; do
    CHAIN_REF=refs/tags/v1.2.3 CHAIN_FAIL="${_j}" run _chain_results "${_out}"
    assert_success
    _chain_check "${output}" "${_j}=failure" release=skipped
    run _chain_rollup "${_out}" "${output}"
    assert_failure 1

    CHAIN_REF=refs/tags/v1.2.3 run _chain_results "${_out}"$'\n'"select_${_j//-/_}=false"
    assert_success
    _chain_check "${output}" "${_j}=skipped" release=skipped
    run _chain_rollup "${_out}"$'\n'"select_${_j//-/_}=false" "${output}"
    assert_success
  done
}

# why: cycle 4. One source for every gate: the map's names,
# the map's --jobs and classify's loop list are the same set, and with the
# release-only jobs the keys the gated jobs' `if:`s read. Each gated job
# reads exactly one select_* key, the one its `if:` names; config-gen-gates
# reads select_config_gen. The rollup must resolve each gated job to
# that same key: its skip fails while the key is `true` and passes once
# that key alone is `false`. The key comes from the job's `if:`, never
# from a rewrite of the job's name, so a rollup that guesses the key from
# the name fails here.
@test "chain: the gated jobs, the map's job list, classify's loop and the release-only jobs are one set, and each selected skip fails the rollup (base#1584, base#2177)" {
  local _gated _map _loop _names _jobs12 _keys _j _k _if
  _names="$(printf '%s\n' config-gen coverage coverage-gate acceptance system \
      worker-selftest shellcheck hadolint bats-fragile \
      test-tools-image-arm64 | LC_ALL=C sort)"
  _jobs12="$(printf '%s\n' config-gen-gates config-gen-redpath coverage coverage-gate \
      acceptance system worker-selftest shellcheck hadolint bats-fragile mutation-roster \
      test-tools-image-arm64 | LC_ALL=C sort)"
  _gated="$(_gated_jobs | LC_ALL=C sort)"
  _map="$(bash /source/script/ci/check_selection.sh --jobs | LC_ALL=C sort)"
  _loop="$(yaml_step_run "${SELF_WF}" classify diff \
      | awk '/for job in config-gen/ {f = 1} f {print} f && /; do$/ {exit}' \
      | sed -e 's/for job in//' -e 's/; do//' -e 's/\\$//' | tr -s ' \n' '\n' \
      | sed '/^$/d' | LC_ALL=C sort)"
  assert_equal "${_gated}" "${_jobs12}"
  assert_equal "${_map}" "${_names}"
  assert_equal "${_loop}" "${_names}"
  local _out _results _bad=""
  local -A _key=()
  while IFS= read -r _j; do
    _if="$(LP_J="${_j}" yq '.jobs[strenv(LP_J)].if' "${SELF_WF}")"
    if [[ "${_if}" =~ ^needs\.classify\.outputs\.(select_[a-z0-9_]+)\ ==\ \'true\'$ ]]; then
      _key["${_j}"]="${BASH_REMATCH[1]}"
    else
      _bad+="${_j}: if: is '${_if}'"$'\n'
    fi
  done <<< "${_jobs12}"
  [[ -z "${_bad}" ]] || fail "${_bad}"
  _keys="$(for _k in "${_key[@]}"; do _k="${_k#select_}"; echo "${_k//_/-}"; done | LC_ALL=C sort -u)"
  assert_equal "${_keys}" "$(printf '%s\n' ${_names} ${RELEASE_JOBS} | LC_ALL=C sort)"
  assert_equal "${_key[config-gen-gates]}" select_config_gen
  assert_equal "${_key[config-gen-redpath]}" select_config_gen_redpath
  # A tag push: the run that selects every gated job, release-only included.
  _out="$(CLASSIFY_REF=refs/tags/v1.2.3 _classify_push zz-new/thing.txt)"
  _results="$(CHAIN_REF=refs/tags/v1.2.3 _chain_results "${_out}")"
  while IFS= read -r _j; do
    _k="${_key[${_j}]}"
    run _chain_rollup "${_out}" "$(sed -E "s/^${_j} .*/${_j} skipped/" <<< "${_results}")"
    [[ "${status}" -eq 1 ]] || _bad+="${_j}: a skip with ${_k}=true exited ${status}"$'\n'
    run _chain_rollup "${_out}"$'\n'"${_k}=false" "$(sed -E "s/^${_j} .*/${_j} skipped/" <<< "${_results}")"
    [[ "${status}" -eq 0 ]] || _bad+="${_j}: a skip with ${_k}=false exited ${status}"$'\n'
  done <<< "${_jobs12}"
  [[ -z "${_bad}" ]] || fail "${_bad}"
}
