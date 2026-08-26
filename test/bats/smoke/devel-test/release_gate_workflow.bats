#!/usr/bin/env bats
#
# Structural lock on the RELEASE INVARIANT, read off .github/workflows/main.yaml
# itself.
#
# The rule is absolute (#70, after v0.3.0-rc1 published with no picture ever
# verified for it): no version may publish without the Tier B picture gate
# having passed on that commit -- no override, no `continue-on-error`, no
# `if: always()` escape, and an unavailable GPU runner BLOCKS the release.
#
# Until this file existed the rule was defended by prose. It lived in `if:` /
# `needs:` expressions and comments in one workflow, and NOTHING read them:
# every gate this repo has -- bats, node, both e2e tiers, hadolint, shellcheck
# -- stays green while the protection is deleted. `|| github.event_name ==
# 'workflow_dispatch'` added to a gate while debugging, or `tier-b-visual-e2e`
# dropped from a `needs:` list, and the next tag publishes blind under a full
# board of green checks. Three audit rounds named that as the largest
# structural risk in the repo and none of them closed it.
#
# WHY THE MUTATIONS. A structural test that reads a file it can only agree with
# is the exact failure this repo has been bitten by three times -- an assertion
# that cannot fail is worse than no assertion, because it also stops anyone
# looking. So every property is proved twice: once against the shipped
# workflow (it must hold) and once against a workflow with that ONE property
# removed (the checker must name it). `_mutate` hard-fails when its sed matches
# nothing, so a mutation that silently stops applying -- because the workflow
# was reworded -- fails the test instead of passing vacuously.
#
# No GPU, no tag push, no GitHub, no network: it is bash + awk over a file.
# script/ci/check_release_gates.sh is copied to /ci/ and the workflow to
# /workflows/ by the `devel-test` stage.

CHECK="/ci/check_release_gates.sh"
WORKFLOW="/workflows/main.yaml"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  MUTATED="${TMP}/mutated.yaml"
}

# _mutate <sed-expr>: write the shipped workflow through <sed-expr> to
# "${MUTATED}". Fails the test if the expression matched nothing -- an
# unapplied mutation would make the case below assert on the UNMODIFIED
# workflow, which is precisely the test-that-cannot-fail this file exists to
# avoid.
_mutate() {
  sed "$1" "${WORKFLOW}" > "${MUTATED}"
  if cmp -s "${MUTATED}" "${WORKFLOW}"; then
    echo "mutation matched nothing, so this case proves nothing: $1" >&2
    return 1
  fi
}

@test "gates: the checker and the workflow are both in the image" {
  assert_file_exists "${CHECK}"
  assert_file_exists "${WORKFLOW}"
}

@test "gates: the shipped workflow holds the release invariant" {
  run bash "${CHECK}" "${WORKFLOW}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# Two vacuity guards. A checker that passes on a file it never read, or on a
# file with no jobs in it, reports "invariant holds" for a workflow that
# protects nothing -- so both are exit 2, distinct from a violation's exit 1.
@test "gates: a workflow that cannot be read is an error, not a pass" {
  run bash "${CHECK}" "${TMP}/does-not-exist.yaml"
  assert_failure 2
  assert_output --partial "cannot read workflow"
}

@test "gates: a workflow with no jobs is an error, not a vacuous pass" {
  printf 'name: Empty\non:\n  push:\njobs:\n' > "${TMP}/empty.yaml"
  run bash "${CHECK}" "${TMP}/empty.yaml"
  assert_failure 2
  assert_output --partial "declares no jobs"
}

# ---------------------------------------------------------------- publish --

@test "gates: dropping tier-b from publish-image's needs is caught" {
  _mutate 's/needs: \[call-docker-build, call-release, tier-b-visual-e2e\]/needs: [call-docker-build, call-release]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-needs-tier-b]"
}

# publish-image's condition opens with `!cancelled()`, which it needs because
# call-release is legitimately skipped on both dispatch paths. That status
# function also stops a SKIPPED need from skipping this job -- so the explicit
# `result == 'success'` is the only thing left blocking an image whose picture
# gate never ran.
@test "gates: dropping publish-image's tier-b success requirement is caught" {
  _mutate '/&& needs\.tier-b-visual-e2e\.result == /d'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-requires-tier-b-success]"
}

# The two mutations that walked through the substring version of the check
# above, both of which publish with no picture verified while every test in
# this repo stays green. They are the named threat model of this whole file
# ("`|| github.event_name == 'workflow_dispatch'` added to a gate while
# debugging"), and until now nothing turned red for either.
#
# M1: the requirement is still THERE, character for character, but it is now
# one alternative of a disjunction -- a hand-typed publish_image_tag satisfies
# it with the gate skipped, failed, or never run.
@test "gates: the tier-b success requirement demoted to an alternative is caught" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& (needs.tier-b-visual-e2e.result == 'success' || inputs.publish_image_tag != '')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-requires-tier-b-success]"
}

# M55: nothing is removed and nothing is wrapped -- one `||` is appended to the
# END of the condition. `&&` binds tighter than `||`, so the whole gate chain
# collapses into one side of a disjunction and the other side publishes alone.
@test "gates: a top-level || appended to publish-image's whole condition is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# ---------------------------------------------------------------- release --

@test "gates: dropping tier-b from call-release's needs is caught" {
  _mutate 's/needs: \[verify-tag-shape, call-docker-build, tier-b-visual-e2e\]/needs: [verify-tag-shape, call-docker-build]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-needs-tier-b]"
}

# The load-bearing ABSENCE. call-release carries no always()/success()/
# failure()/cancelled(), which is what keeps GitHub's default rule ("a job is
# skipped when a job it needs did not succeed") in force -- and that default is
# the entire mechanism by which an unavailable GPU runner blocks a release.
# Adding a status function here reads like a harmless robustness tweak and
# quietly converts a blocked release into a published one.
@test "gates: adding a status function to call-release's if is caught" {
  _mutate "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# ------------------------------------------------------------------ gates --

@test "gates: continue-on-error on a gate job is caught" {
  _mutate '/^  tier-b-visual-e2e:$/a\    continue-on-error: true'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-has-no-continue-on-error]"
}

# Everything above reads JOB level, and a job's `result` is the only thing a
# `needs:` or a `needs.*.result` check can see -- so a gate job that runs but
# does NOTHING satisfies every one of them. These two mutations do that, with
# no override input and no status function anywhere in the file.
#
# M9: the Tier B acceptance STEP (not the job) is given
# `if: github.event_name == 'schedule'`. On a tag push the job runs, the one
# step that boots a producer and looks at a frame is skipped, the job
# concludes `success`, publish-image is satisfied and the image is published
# with no picture ever taken.
@test "gates: an if: on the Tier B acceptance STEP is caught" {
  _mutate "/^      - name: Tier B visual acceptance/a\\        if: github.event_name == 'schedule'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# M54: the same shape on verify-tag-shape's only working step. The shape check
# never runs, the job succeeds, and a tag the image-tag deriver cannot publish
# reaches call-release -- the exact ordering failure that job exists to stop.
@test "gates: if: false on verify-tag-shape's only step is caught" {
  _mutate "s#^        if: \${{ github.ref_type == 'tag' }}\$#        if: false#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# The other half of that property: deleting the work step entirely must not be
# a pass either. A gate job with nothing in it is a gate in name only.
@test "gates: deleting the Tier B acceptance step is caught" {
  _mutate '/^      - name: Tier B visual acceptance/,/^      - name: Upload evidence/{/^      - name: Upload evidence/!d}'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# release-blocked-report / nightly-tier-b-report use `always()` and exist only
# to turn a silently blocked release into a red run. Nothing may need one: a
# job that waits on them would inherit an always()-gated dependency, which is
# the escape the picture-gate rule forbids.
@test "gates: making a report-only job a dependency is caught" {
  _mutate 's/needs: \[call-docker-build, call-release, tier-b-visual-e2e\]/needs: [call-docker-build, call-release, tier-b-visual-e2e, release-blocked-report]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[no-job-needs-a-report-only-job]"
}

# M33. `needs:` was read as a STRING and searched for a substring, so a job
# merely NAMED after the gate satisfied it. Append an `always()`-gated
# `tier-b-visual-e2e-summary` and point call-release at it: the substring
# `tier-b-visual-e2e` is present in the needs list, and a Release is cut for a
# commit whose Tier B failed. Two independent properties must now catch this --
# needs is a LIST and membership is exact, and nothing may need a job whose own
# condition carries a status function.
@test "gates: a decoy job named after the gate does not satisfy a needs" {
  {
    sed 's/needs: \[verify-tag-shape, call-docker-build, tier-b-visual-e2e\]/needs: [verify-tag-shape, call-docker-build, tier-b-visual-e2e-summary]/' \
      "${WORKFLOW}"
    printf '%s\n' \
      "  tier-b-visual-e2e-summary:" \
      "    needs: [tier-b-visual-e2e]" \
      "    if: always()" \
      "    runs-on: ubuntu-latest" \
      "    steps:" \
      "      - name: Summarise" \
      "        run: echo done"
  } > "${MUTATED}"
  run grep -qF 'tier-b-visual-e2e-summary]' "${MUTATED}"
  assert_success
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-needs-tier-b]"
  assert_output --partial "[no-job-needs-a-status-gated-job]"
}

# A `needs:` naming a job that is not in the file is a workflow GitHub refuses
# to run; this checker must not read the dangling name's absent condition as
# "no status function" and report the invariant as held.
@test "gates: a needs naming a job that does not exist is caught" {
  _mutate 's/needs: \[verify-tag-shape\]$/needs: [verify-tag-shape-v2]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[needs-name-a-job-that-exists]"
}

# M2. Every property above names call-release and publish-image, because those
# were the two jobs that published anything when they were written. A name list
# cannot see a new entry: this job logs in to GHCR and pushes an image, needs
# only the build, and is behind no gate whatsoever -- and nothing in this file
# looked at it. The set of jobs that can publish is now DERIVED from the file.
@test "gates: a NEW publishing job with no picture gate is caught" {
  {
    cat "${WORKFLOW}"
    printf '%s\n' \
      "  publish-image-hotfix:" \
      "    needs: [call-docker-build]" \
      "    runs-on: ubuntu-latest" \
      "    permissions:" \
      "      contents: read" \
      "      packages: write" \
      "    steps:" \
      "      - name: Log in to GHCR" \
      "        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0" \
      "      - name: Build and push the runtime image" \
      "        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0" \
      "        with:" \
      "          push: true"
  } > "${MUTATED}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-image-hotfix"
}

# The vacuity guard for that derivation: a checker that can no longer find
# ANYTHING that publishes must say so rather than report an invariant holding
# over a workflow it has stopped understanding.
@test "gates: a workflow whose jobs publish nothing is an error, not a pass" {
  printf 'name: X\non:\n  push:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' \
    > "${TMP}/nopub.yaml"
  run bash "${CHECK}" "${TMP}/nopub.yaml"
  assert_failure 1
  assert_output --partial "[publishing-jobs-are-identifiable]"
}

# M52. The gate's whole job is to boot a real Kit producer and assert a real
# browser renders a non-black frame from it, and no hosted runner has NVENC --
# so moving it to ubuntu-latest does not make the gate slower, it removes it.
# Nothing pinned the runner.
@test "gates: moving the picture gate off the GPU runner is caught" {
  _mutate 's/^    runs-on: \[self-hosted, gpu\]$/    runs-on: ubuntu-latest/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# ------------------------------------------------------- tag reachability --

@test "gates: removing the tag push trigger is caught" {
  _mutate "/^      - 'v\[0-9\]/d"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[workflow-triggers-on-tag-push]"
}

@test "gates: tier-b losing its bare tag-push alternative is caught" {
  _mutate "s#^      || startsWith(github.ref, 'refs/tags/')\$#      || startsWith(github.ref, 'refs/heads/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-reachable-on-every-tag-push]"
}

# The subtler half: the tag alternative is still THERE, but ANDed instead of
# ORed, so the condition is false for an ordinary tag push. A substring grep
# would pass this; splitting the expression at parenthesis depth 0 does not.
@test "gates: tier-b's tag alternative becoming a top-level AND is caught" {
  _mutate "s#^      || startsWith(github.ref, 'refs/tags/')\$#      \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-reachable-on-every-tag-push]"
}

# tier-b-visual-e2e needs verify-tag-shape, and a SKIPPED need skips its
# dependent. verify-tag-shape carries no job-level `if:` for exactly that
# reason -- the tag check is guarded per-step instead -- so an `if:` added here
# makes the picture gate skippable on paths nobody intended.
@test "gates: giving verify-tag-shape a job-level if is caught" {
  _mutate "/^  verify-tag-shape:\$/a\\    if: \${{ github.ref_type == 'tag' }}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[verify-tag-shape-has-no-job-level-if]"
}
