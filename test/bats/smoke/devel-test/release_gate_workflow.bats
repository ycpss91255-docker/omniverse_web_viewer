#!/usr/bin/env bats
#
# Structural lock on the RELEASE INVARIANT, read off .github/workflows/main.yaml
# itself.
#
# The rule is absolute (#70, after v0.3.0-rc1 published with no picture ever
# verified for it): no version may publish without the Tier B picture gate
# having passed on that commit -- no override, no `continue-on-error`, no
# status-function escape, and an unavailable GPU runner BLOCKS the release.
#
# Until this file existed the rule was defended by prose. It lived in `if:` /
# `needs:` expressions and comments in one workflow, and NOTHING read them:
# every gate this repo has -- bats, node, both e2e tiers, hadolint, shellcheck
# -- stays green while the protection is deleted.
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
# WHY THE PASSING CASES. Several cases here assert the checker SUCCEEDS, on
# workflows rewritten in a semantically identical way. That is not padding: a
# checker that reports a correct edit as a violation teaches maintainers it is
# noise, and a gate people have learned to work around is the same board of
# green checks with extra ceremony. Each is paired with a failing case using
# the same spelling, so the acceptance cannot widen into a blanket pass.
#
# WHY THERE ARE TWO REVIEWS' WORTH OF CASES BELOW. Round 4's checker was
# walked past by 12 mutations. Round 5 hardened it to ~885 lines of bash and
# awk and a reviewer walked 21 more past THAT, four of which removed the
# picture gate entirely while the checker printed "holds the release
# invariant". Almost none of the 21 were mistakes in an individual rule; they
# were properties of reading YAML with line regexes -- trailing comments,
# `"if":` / `'if':` / `if :` as four spellings of one key, a `(` inside a
# quoted string breaking parenthesis depth, a job header with a trailing
# comment not being a job. The checker is now a YAML PARSE
# (script/ci/check_release_gates.py, PyYAML, installed in `devel-test` only),
# and each of those 21 mutations is a case below UNDER ITS REVIEW NAME, along
# with the 4 legal edits the old checker reported as violations.
#
# NAMES. The review's own report was not available to this file's author, so
# the 25 identifiers below (C3 C4 C5 T1 J1 U1 U2 D1 B1 B2 E1 E2 E3 G1 F1 F2
# N4 N5 H1 H2 M5 I1 I2 P3 P4) are attached to mutations RECONSTRUCTED from the
# round-6 brief's description of each root cause. Each was verified to pass
# the round-5 checker before the rewrite and to be caught after it; the
# verification, not the naming, is the load-bearing part.
#
# WHAT IS NOT COVERED HERE is not restated here either. The canonical list of
# what the checker cannot see is the header of
# script/ci/check_release_gates.py, and it is canonical because four
# restatements of it in four documents had already drifted into four different
# lists, none of which mentioned the comment channel -- the single most
# productive attack in the last review.
#
# No GPU, no tag push, no GitHub, no network: it is a parse of a file.
# script/ci/ is copied to /ci/ and the workflow to /workflows/ by the
# `devel-test` stage.

CHECK="/ci/check_release_gates.sh"
CHECKER_PY="/ci/check_release_gates.py"
WORKFLOW="/workflows/main.yaml"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  MUTATED="${TMP}/mutated.yaml"
}

# _mutate <sed-expr>...: write the shipped workflow through every <sed-expr>
# to "${MUTATED}". Fails the test if the result is unchanged -- an unapplied
# mutation would make the case below assert on the UNMODIFIED workflow, which
# is precisely the test-that-cannot-fail this file exists to avoid.
_mutate() {
  local args=()
  local expr
  for expr in "$@"; do args+=(-e "${expr}"); done
  sed "${args[@]}" "${WORKFLOW}" > "${MUTATED}"
  if cmp -s "${MUTATED}" "${WORKFLOW}"; then
    echo "mutation matched nothing, so this case proves nothing: $*" >&2
    return 1
  fi
}

# _append_job: append the job on stdin to a copy of the shipped workflow.
_append_job() {
  { cat "${WORKFLOW}"; cat; } > "${MUTATED}"
  if cmp -s "${MUTATED}" "${WORKFLOW}"; then
    echo "nothing was appended, so this case proves nothing" >&2
    return 1
  fi
}

@test "gates: the checker and the workflow are both in the image" {
  assert_file_exists "${CHECK}"
  assert_file_exists "${CHECKER_PY}"
  assert_file_exists "${WORKFLOW}"
}

# The checker is Python now, and shellcheck's `/ci/*.sh` glob cannot lint it.
# A syntax error would otherwise reach a maintainer as "exit 2 on every
# workflow", which reads like a broken input rather than a broken checker.
@test "gates: the checker byte-compiles" {
  run python3 -m py_compile "${CHECKER_PY}"
  assert_success
}

# The one dependency, asserted in the image that is supposed to have it. The
# `devel-test` stage installs python3-yaml; nothing shipped is FROM this
# stage, so this is also the assertion that the install landed where it was
# meant to.
@test "gates: the image the checker runs in has PyYAML" {
  run python3 -c 'import yaml; print(yaml.__version__)'
  assert_success
}

@test "gates: the shipped workflow holds the release invariant" {
  run bash "${CHECK}" "${WORKFLOW}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ------------------------------------------------------------- vacuity ----
#
# A checker that passes on a file it never read, or never understood, reports
# "invariant holds" for a workflow that protects nothing. Every one of these
# is exit 2, distinct from a violation's exit 1, and every one says something
# before it goes.
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

# New with the parser: a file that is not YAML at all used to be read line by
# line and reported on regardless.
@test "gates: a workflow that is not valid YAML is an error, not a pass" {
  printf 'jobs:\n  a: [\n' > "${TMP}/bad.yaml"
  run bash "${CHECK}" "${TMP}/bad.yaml"
  assert_failure 2
  assert_output --partial "cannot parse workflow"
}

# Also new: a duplicate key is last-wins in PyYAML and rejected by GitHub. A
# job with `if:` twice would be read as one condition here and another by the
# maintainer reading top to bottom, and the disagreement is invisible both
# ways.
@test "gates: a duplicate key in a job is refused rather than silently resolved" {
  _mutate "/^  publish-image:\$/a\\    if: false"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 2
  assert_output --partial "duplicate key"
}

# The dependency check is a REFUSAL, not a skip. A checker that quietly does
# nothing when its parser is missing is the silent green board this whole file
# exists to end -- so the missing-PyYAML path is exercised with a python3 that
# cannot import it.
@test "gates: a python3 without PyYAML is refused, not skipped" {
  mkdir -p "${TMP}/fakebin"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "${TMP}/fakebin/python3"
  chmod +x "${TMP}/fakebin/python3"
  PATH="${TMP}/fakebin:${PATH}" run bash "${CHECK}" "${WORKFLOW}"
  assert_failure 2
  assert_output --partial "no PyYAML"
  assert_output --partial "NOT verified"
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

# The load-bearing ABSENCE. call-release carries no status function, which is
# what keeps GitHub's default rule ("a job is skipped when a job it needs did
# not succeed") in force -- and that default is the entire mechanism by which
# an unavailable GPU runner blocks a release. Adding one here reads like a
# harmless robustness tweak and quietly converts a blocked release into a
# published one.
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

# The id a missing gate job is reported under used to be
# `gate-job-has-no-continue-on-error`, which is not what happened: the job is
# absent, and it has no continue-on-error precisely because it has nothing.
# Reading that message sends a maintainer looking for a flag that is not
# there.
@test "gates: a gate job that is gone is reported as gone" {
  awk '/^  publish-image:$/ { d = 1 } d && /^  tier-b-visual-e2e:$/ { d = 0 } !d' \
    "${WORKFLOW}" > "${MUTATED}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-is-defined]"
  assert_output --partial "publish-image"
  refute_output --partial "[gate-job-has-no-continue-on-error] gate job 'publish-image'"
}

# Everything above reads JOB level, and a job's `result` is the only thing a
# `needs:` or a `needs.*.result` check can see -- so a gate job that runs but
# does NOTHING satisfies every one of them.
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

# M16. publish-image carries `!cancelled()` deliberately. `always()` is not the
# same tool: it also runs the job in a CANCELLED run, and a cancelled Tier B --
# evicted from the GPU concurrency group as a pending member -- is a
# documented, recurring case in this workflow. Not a bypass on its own, since
# the explicit `result == 'success'` conjunct still holds; it removes the
# second of the two independent things stopping the push.
#
# The id is `publish-image-status-function-is-narrow`, not the round-5
# `publish-image-carries-no-always`. The rename is the point of the case
# below: the property is about what the condition MEANS in a cancelled run,
# and naming it after one literal is what let a second literal through.
@test "gates: always() in place of publish-image's !cancelled() is caught" {
  _mutate 's/^      !cancelled()$/      always()/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-status-function-is-narrow]"
}

# M33. `needs:` was read as a STRING and searched for a substring, so a job
# merely NAMED after the gate satisfied it. Two independent properties catch
# this -- needs is a LIST and membership is exact, and nothing may need a job
# whose own condition carries a status function.
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

# Reading `needs:` as a list rather than a string is only an improvement if it
# still reads the OTHER valid spellings of the same list.
@test "gates: a quoted needs list is read as the same list" {
  _mutate 's/needs: \[verify-tag-shape, call-docker-build, tier-b-visual-e2e\]/needs: ["verify-tag-shape", "call-docker-build", "tier-b-visual-e2e"]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
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

# M2. A name list cannot see a new entry: this job logs in to GHCR and pushes
# an image, needs only the build, and is behind no gate whatsoever. The set of
# jobs that can publish is DERIVED from the file.
@test "gates: a NEW publishing job with no picture gate is caught" {
  _append_job <<'JOB'
  publish-image-hotfix:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Log in to GHCR
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
      - name: Build and push the runtime image
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          push: true
JOB
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

# M50. Property 6 forbids DEPENDING on the report-only jobs. It said nothing
# about them existing, so deleting both was invisible -- and nothing else in
# the repo would notice either, because by design nothing depends on them.
@test "gates: deleting the report-only jobs is caught" {
  _mutate '/^  release-blocked-report:$/,$d'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[report-only-jobs-still-exist]"
}

# Half a deletion is the same loss: a report that can no longer observe a need
# which did not succeed reports nothing.
@test "gates: a report-only job that can no longer observe the gate is caught" {
  _mutate "s/^      && needs.tier-b-visual-e2e.result != 'success'\$/      \&\& needs.tier-b-visual-e2e.result == 'failure'/"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[report-only-jobs-still-exist]"
}

# M52. The gate's whole job is to boot a real Kit producer and assert a real
# browser renders a non-black frame from it, and no hosted runner has NVENC --
# so moving it to ubuntu-latest does not make the gate slower, it removes it.
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

# M20. Property 7 asked whether `on.push.tags` had any items in it, not
# whether a real version tag matches one. Both shapes this repo cuts are
# probed, because the incident behind the rule was an rc.
@test "gates: tag globs that match no real version are caught" {
  _mutate "s/^      - 'v\[0-9\].*\$/      - 'never-matches-anything'/"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-globs-match-a-real-version]"
}

@test "gates: tag globs that stop matching pre-release tags are caught" {
  _mutate "/^      - 'v\[0-9\]+.\[0-9\]+.\[0-9\]+-\*'\$/d"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-globs-match-a-real-version]"
  assert_output --partial "v1.2.3-rc1"
}

@test "gates: tier-b losing its bare tag-push alternative is caught" {
  _mutate "s#^      || startsWith(github.ref, 'refs/tags/')\$#      || startsWith(github.ref, 'refs/heads/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-reachable-on-every-tag-push]"
}

# The subtler half: the tag alternative is still THERE, but ANDed instead of
# ORed, so the condition is false for an ordinary tag push.
@test "gates: tier-b's tag alternative becoming a top-level AND is caught" {
  _mutate "s#^      || startsWith(github.ref, 'refs/tags/')\$#      \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-reachable-on-every-tag-push]"
}

# ------------------------------------------- equivalent spellings pass -----
#
# M22: `github.ref_type == 'tag'` -- rejected by round 4 even though
# verify-tag-shape ten lines away in the same file guards its own step with
# exactly that spelling.
@test "gates: github.ref_type == 'tag' is accepted as the tag-ref test" {
  _mutate "s#^      || startsWith(github.ref, 'refs/tags/')\$#      || github.ref_type == 'tag'#"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# M6: the same condition written as one `${{ }}`-wrapped line with the tag
# alternative LAST. The wrapper is Actions notation, not part of the
# expression, and order does not change a disjunction.
@test "gates: a \${{ }}-wrapped tier-b condition with the tag test last passes" {
  new_if="    if: \${{ github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && (inputs.run_tier_b || inputs.publish_image_tag != '')) || startsWith(github.ref, 'refs/tags/') }}"
  awk -v repl="${new_if}" '
    /^  tier-b-visual-e2e:$/ { intb = 1 }
    intb && !done && /^    if: >-$/ { print repl; skip = 1; done = 1; next }
    skip && /^    runs-on:/ { skip = 0 }
    skip { next }
    { print }
  ' "${WORKFLOW}" > "${MUTATED}"
  if cmp -s "${MUTATED}" "${WORKFLOW}"; then
    echo "rewrite matched nothing, so this case proves nothing" >&2
    return 1
  fi
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# And the rewrite above must not have become a blanket pass: the SAME `${{ }}`
# spelling with the tag alternative removed is still caught.
@test "gates: a \${{ }}-wrapped tier-b condition missing the tag test is caught" {
  new_if="    if: \${{ github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && (inputs.run_tier_b || inputs.publish_image_tag != '')) }}"
  awk -v repl="${new_if}" '
    /^  tier-b-visual-e2e:$/ { intb = 1 }
    intb && !done && /^    if: >-$/ { print repl; skip = 1; done = 1; next }
    skip && /^    runs-on:/ { skip = 0 }
    skip { next }
    { print }
  ' "${WORKFLOW}" > "${MUTATED}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-reachable-on-every-tag-push]"
}

# tier-b-visual-e2e needs verify-tag-shape, and a SKIPPED need skips its
# dependent. verify-tag-shape carries no job-level `if:` for exactly that
# reason -- the tag check is guarded per-step instead.
@test "gates: giving verify-tag-shape a job-level if is caught" {
  _mutate "/^  verify-tag-shape:\$/a\\    if: \${{ github.ref_type == 'tag' }}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[verify-tag-shape-has-no-job-level-if]"
}

# ==========================================================================
# THE 21 MUTATIONS THE ROUND-5 CHECKER DID NOT CATCH
# ==========================================================================
#
# --- root cause 1: the comment channel ------------------------------------
# normalize() stripped whole-line comments only, and six assertions were
# substring tests over raw values. A trailing `#` satisfied or evaded every
# one of them. The parser makes the channel not exist: a comment is not part
# of a value.

# C3. The gate's work step runs `true`. The helper it is supposed to run
# survives in a trailing comment, which is all the "is there still work here"
# check was reading -- so the job ran, did nothing, reported success, and the
# image published with no picture taken.
@test "gates: C3 -- the Tier B work step neutered by a trailing comment is caught" {
  _mutate 's|^        run: bash script/ci/tier_b_visual_e2e.sh$|        run: "true"  # bash script/ci/tier_b_visual_e2e.sh|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# C4. The GPU pin defeated the same way: `self-hosted` and `gpu` are both
# still in the line, in the comment, and the gate ran on a hosted runner with
# no NVENC -- which does not slow the picture check down, it removes it.
@test "gates: C4 -- the GPU pin defeated by a trailing comment is caught" {
  _mutate 's|^    runs-on: \[self-hosted, gpu\]$|    runs-on: ubuntu-latest  # was [self-hosted, gpu]|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# C5. Both report-only jobs neutered: their condition is now `false`, and the
# `!= 'success'` the shape check looked for survives in the comment. A blocked
# release goes back to being a grey job on a green-looking run.
@test "gates: C5 -- a report-only job neutered by a trailing comment is caught" {
  _mutate "s|^      && needs.tier-b-visual-e2e.result != 'success'\$|      \&\& false  # needs.tier-b-visual-e2e.result != 'success'|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[report-only-jobs-still-exist]"
}

# T1. `steps:` with a trailing comment is not `steps:` to a line regex, so
# NOTHING below it was parsed and every step-level `if:` in publish-image
# became invisible -- here, on the step that actually pushes. The job reports
# success having published nothing, and a tag cuts a Release with no image
# behind it: the exact state this workflow's own header argues against.
@test "gates: T1 -- a commented steps: hiding an if: on the push step is caught" {
  _mutate '/^  publish-image:$/,/^  tier-b-visual-e2e:$/{s|^    steps:$|    steps:  # the publish work|}' \
          '/^      - name: Build and push the runtime image$/a\        if: false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-step-is-unconditional]"
}

# J1. A job header with a trailing comment is not a job header to a line
# regex: the job is invisible to the job list, so it is never derived as
# publishing and never required to carry the gate, while its body is silently
# attributed to the job above it. Placed directly above tier-b-visual-e2e so
# the lines it leaks land in publish-image, which is behind the gate already
# -- nothing else in the file changes its verdict, which is what made this
# silent.
@test "gates: J1 -- a job header with a trailing comment is still a job" {
  awk '
    /^  tier-b-visual-e2e:$/ && !done {
      print "  publish-image-hotfix:  # emergency path, bypasses the queue"
      print "    needs: [call-docker-build]"
      print "    runs-on: ubuntu-latest"
      print "    permissions:"
      print "      contents: read"
      print "      packages: write"
      print "    steps:"
      print "      - name: Push"
      print "        run: docker push ghcr.io/x/y:z"
      done = 1
    }
    { print }
  ' "${WORKFLOW}" > "${MUTATED}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-image-hotfix"
}

# --- root cause 2: one spelling per construct ------------------------------
# `if:`, `"if":`, `'if':` and `if :` are four valid YAML spellings of one key.
# A regex anchored on one of them cannot see the other three, at STEP level
# and at JOB level, and in both places the check being evaded is one where
# ABSENCE means "fine".

# U1/U2/D1: the Tier B acceptance step is disabled outright. The job runs, the
# one step that looks at a frame does not, the job reports success, and the
# image publishes.
@test "gates: U1 -- a double-quoted \"if\": on the Tier B work step is caught" {
  _mutate '/^      - name: Tier B visual acceptance/a\        "if": false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

@test "gates: U2 -- a single-quoted 'if': on the Tier B work step is caught" {
  _mutate "/^      - name: Tier B visual acceptance/a\\        'if': false"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

@test "gates: D1 -- a spaced 'if :' on the Tier B work step is caught" {
  _mutate '/^      - name: Tier B visual acceptance/a\        if : false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# B1/B2/E1: the same three spellings at JOB level, on call-release, where the
# property is the ABSENCE of a status function. A status function there
# overrides GitHub's default skip propagation, so a skipped picture gate stops
# blocking the Release -- and the key it is written under was invisible.
@test "gates: B1 -- a double-quoted \"if\": hiding a status function on call-release is caught" {
  _mutate '/^  call-release:$/,/^  publish-image:$/{s|^    if: >-$|    "if": >-|}' \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

@test "gates: B2 -- a single-quoted 'if': hiding a status function on call-release is caught" {
  _mutate "/^  call-release:\$/,/^  publish-image:\$/{s|^    if: >-\$|    'if': >-|}" \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

@test "gates: E1 -- a spaced 'if :' hiding a status function on call-release is caught" {
  _mutate '/^  call-release:$/,/^  publish-image:$/{s|^    if: >-$|    if : >-|}' \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# E2/E3: the same at job level on verify-tag-shape, where ANY job-level `if:`
# is forbidden -- it is a need of the picture gate, and a skipped need skips
# its dependent, so this job must always run.
@test "gates: E2 -- a double-quoted \"if\": on verify-tag-shape is caught" {
  _mutate '/^  verify-tag-shape:$/a\    "if": false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[verify-tag-shape-has-no-job-level-if]"
}

@test "gates: E3 -- a spaced 'if :' on verify-tag-shape is caught" {
  _mutate '/^  verify-tag-shape:$/a\    if : false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[verify-tag-shape-has-no-job-level-if]"
}

# --- root cause 3: parenthesis depth that is not string-literal aware ------
# The round-5 tokeniser counted every `(` and `)` in the text, including
# inside quoted strings. One unbalanced parenthesis inside a literal pinned
# depth off zero for the rest of the expression, and every top-level operator
# after it stopped being top-level -- walking a `||` straight past the check
# whose entire claim was to be structural rather than a grep.

# G1. An unbalanced `(` inside a string pins depth ABOVE zero, so the `||`
# appended after it is invisible and the whole gate chain becomes one
# alternative of a disjunction.
@test "gates: G1 -- a '(' inside a string hiding a top-level || is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      \&\& !contains(github.ref_name, '(')\n      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# F1. The same in the other direction: a `)` inside a string drives depth
# BELOW zero, with the same effect and from the opposite side.
@test "gates: F1 -- a ')' inside a string hiding a top-level || is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      \&\& !contains(github.ref_name, ')')\n      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# ... and the acceptance half, so the fix is a tokeniser and not a ban on
# parentheses in strings: a condition that legitimately mentions one still
# passes.
@test "gates: a parenthesis inside a string literal is not a bypass by itself" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& needs.tier-b-visual-e2e.result == 'success'\n      \&\& !contains(github.ref_name, '(')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# A condition whose parentheses do not balance outside its strings cannot be
# split into terms at all. Guessing at one and reporting the invariant as held
# is the failure mode; refusing is not.
@test "gates: an unbalanced condition is refused rather than mis-split" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& (needs.tier-b-visual-e2e.result == 'success'#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[condition-is-a-well-formed-expression]"
}

# F2. A publishing command split across a folded scalar never appears
# contiguously in the raw text, so a substring search over the job body could
# not find it and the job was never derived as one that publishes. The parser
# folds the scalar before anything looks at it.
@test "gates: F2 -- a publishing command folded across lines is still publishing" {
  _append_job <<'JOB'
  publish-npm:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Publish
        run: >-
          npm
          publish
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-npm"
}

# --- root cause 4: allowlists wearing the word "derived" -------------------
# The publishing set was called DERIVED, but it was derived by searching for
# nine literal strings. `write-all`, `docker buildx build --push`, a `push:`
# whose value is an expression, and a workflow-level `permissions:` block are
# all ordinary spellings none of the nine matched.

# N4. `permissions: write-all` is one token and grants every scope there is.
@test "gates: N4 -- permissions: write-all is a publishing job" {
  _append_job <<'JOB'
  publish-anything:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    permissions: write-all
    steps:
      - name: Ship
        uses: some/publishing-action@v1
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-anything"
}

# N5. A workflow-level `permissions:` block is the grant every job WITHOUT its
# own block runs with. Reading only job-level blocks meant a workflow that
# handed write to everything looked read-only.
@test "gates: N5 -- a workflow-level permissions grant reaches every job" {
  {
    sed '2i\permissions:\n  contents: write\n  packages: write' "${WORKFLOW}"
    printf '%s\n' \
      "  publish-inherited:" \
      "    needs: [call-docker-build]" \
      "    runs-on: ubuntu-latest" \
      "    steps:" \
      "      - name: Ship" \
      "        uses: some/publishing-action@v1"
  } > "${MUTATED}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-inherited"
}

# H1. `docker buildx build --push` names neither `docker push` nor
# `push: true`, which were the two docker spellings on the list.
@test "gates: H1 -- docker buildx build --push is publishing" {
  _append_job <<'JOB'
  publish-buildx:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Build and push
        run: docker buildx build --push -t ghcr.io/x/y:z .
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-buildx"
}

# H2. `push:` with an expression value could be true on any run; the list held
# the literal `push: true`.
@test "gates: H2 -- push: with an expression value is publishing" {
  _append_job <<'JOB'
  publish-expr:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Build and push
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          push: ${{ github.event_name == 'push' }}
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-expr"
}

# ... and the acceptance half of the same widening: `push: false` is a build
# that does not push, and reporting it as a publishing job would teach a
# maintainer that the derivation is noise.
@test "gates: a build that explicitly does not push is not a publishing job" {
  _append_job <<'JOB'
  build-only:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Build
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          push: false
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# --- root cause 5: always() banned by name, not by property ---------------

# M5. `!failure()` is true in a cancelled run, exactly like `always()`. The
# round-5 check tested for the literal `always(`, so the same escape under
# another name walked through -- and a cancelled Tier B, evicted from the GPU
# concurrency group as a pending member, is a documented case here.
@test "gates: M5 -- !failure() in place of publish-image's !cancelled() is caught" {
  _mutate 's/^      !cancelled()$/      !failure()/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-status-function-is-narrow]"
}

# ... and the acceptance half: the two other spellings of the SAME narrow test
# must not be reported as violations, or the property becomes a ban on one
# literal all over again.
@test "gates: cancelled() == false is accepted as the narrow status test" {
  _mutate 's/^      !cancelled()$/      cancelled() == false/'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ==========================================================================
# THE 4 LEGAL EDITS THE ROUND-5 CHECKER REPORTED AS VIOLATIONS
# ==========================================================================
#
# A checker that reports a correct edit as a violation is not merely noisy: it
# teaches maintainers that the gate is noise, and a gate people have learned
# to route around is how a real violation gets waved past next time. Each of
# these was a false positive; each is paired above or below with a case
# proving the acceptance did not widen into a blanket pass.

# I1. `continue-on-error: false` is the DEFAULT written out loud. The check
# was a substring search for the word.
@test "gates: I1 -- continue-on-error: false is not a violation" {
  _mutate '/^  tier-b-visual-e2e:$/a\    continue-on-error: false'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# I2. A trailing comment after a needs list was split on whitespace along with
# the list, and the words in it were reported as jobs that do not exist ("#",
# "the", "picture", "gate").
@test "gates: I2 -- a trailing comment after needs: is not four missing jobs" {
  _mutate 's|^    needs: \[call-docker-build, call-release, tier-b-visual-e2e\]$|    needs: [call-docker-build, call-release, tier-b-visual-e2e]  # the picture gate|'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# P3. `'on':` is the YAML-1.1-safe spelling of the trigger key -- YAML 1.1
# resolves a bare `on` to the boolean true, which is why the quoted form
# exists. Reading only the bare spelling reported a workflow with no triggers
# at all.
@test "gates: P3 -- the quoted 'on': trigger key is read" {
  _mutate "3s|^on:\$|'on':|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# P4. Expressions were compared as strings against literal spellings, so the
# optional whitespace was load-bearing: `result=='success'` and
# `startsWith(github.ref,'refs/tags/')` are the same expressions the workflow
# already contains, written without spaces GitHub does not require.
@test "gates: P4 -- equivalent expressions without optional whitespace pass" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& needs.tier-b-visual-e2e.result=='success'#" \
          "s#^      || startsWith(github.ref, 'refs/tags/')\$#      || startsWith(github.ref,'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ... and the pairing that stops P4's whitespace-insensitivity widening into
# "any expression containing the right words": the same spelling with the
# operand changed is still caught.
@test "gates: whitespace insensitivity does not accept a different expression" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& needs.tier-b-visual-e2e.result=='failure'#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-requires-tier-b-success]"
}

# ==========================================================================
# NO SILENT EXIT
# ==========================================================================
#
# The awk implementation this replaced could die with status 141 and NO
# OUTPUT AT ALL -- a SIGPIPE between two of its own helpers, deterministic on
# the J1 input above. A checker that says nothing and exits non-zero teaches a
# maintainer to re-run it until it is quiet, which is worse than one that
# passes: it is a gate with a retry button. Every exit says something.
@test "gates: the checker never exits without saying why" {
  awk '
    /^  tier-b-visual-e2e:$/ && !done {
      print "  publish-image-hotfix:  # emergency path, bypasses the queue"
      print "    needs: [call-docker-build]"
      print "    runs-on: ubuntu-latest"
      print "    steps:"
      print "      - name: Push"
      print "        run: docker push ghcr.io/x/y:z"
      done = 1
    }
    { print }
  ' "${WORKFLOW}" > "${MUTATED}"
  run bash "${CHECK}" "${MUTATED}"
  refute_output ""
  case "${status}" in
    0 | 1 | 2) ;;
    *)
      echo "checker exited ${status}; only 0, 1 and 2 are defined" >&2
      return 1
      ;;
  esac
}
