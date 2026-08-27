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
# WHY THERE ARE THREE REVIEWS' WORTH OF CASES BELOW. Round 4's checker was
# walked past by 12 mutations. Round 5 hardened it to ~885 lines of bash and
# awk and a reviewer walked 21 more past THAT, four of which removed the
# picture gate entirely while the checker printed "holds the release
# invariant". Round 6 replaced it with a YAML PARSE
# (script/ci/check_release_gates.py, PyYAML, installed in `devel-test` only)
# and a reviewer landed 39 more, of which a further 15 walked through --
# including `if: ALWAYS()`, which defeated the whole invariant because the
# status-function match was case-SENSITIVE, and eight that turned the gate's
# own work step into a no-op while an unconditional decoy kept the "there is
# still work here" COUNT satisfied.
#
# Round 7 closed those two and a reviewer landed 39 more against IT, whose
# misses shared ONE root cause: the gate's driver was pinned as a STRING and
# not as an INVOCATION. Four sibling keys decide what a `run:` string
# actually does -- `shell:`, `working-directory:`, `env:` and `defaults.run`
# at job or workflow level -- and the checker read none of them, so six
# mutations published with no picture, three of them without touching the
# pinned line at all. Plus one bypass that needed no edit to any watched
# file: a SECOND workflow in `.github/workflows/`, which nothing enumerated.
# Those are the cases marked "root cause 7b", "root cause 7c" and the
# `/workflows/` case at the top of this file.
#
# NAMES. Cases here are named for WHAT THEY DO, not for a reviewer's label.
# An earlier version of this file carried 25 identifiers (C3 C4 C5 T1 J1 U1 U2
# D1 B1 B2 E1 E2 E3 G1 F1 F2 N4 N5 H1 H2 M5 I1 I2 P3 P4) reconstructed from a
# brief rather than from the review's own corpus, and a later reviewer who had
# the corpus found 24 of the 25 sitting on a DIFFERENT mutation than the one
# they claimed -- several of them exact pair-swaps. Five of those names sat on
# green cases while the bypass they named was still live, which is strictly
# worse than an admitted gap: someone auditing "did we close I2?" finds a
# passing case called I2 and stops looking. So the labels are gone and the
# claim that went with them ("each of those 21 mutations is a case below under
# its review name") is deleted rather than repaired: it was false as written
# and this file cannot verify a mapping it does not have. What IS verifiable
# is that each case below applies a mutation to the real workflow and asserts
# the checker names the property -- and `_mutate` hard-fails when its sed
# matches nothing, so a case that has quietly stopped mutating anything fails
# instead of passing vacuously.
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

# LIMITATION 1, MADE LOUD.
#
# The checker reads ONE file, and until now nothing enumerated
# `.github/workflows/`: the Dockerfile copied `main.yaml` by name. A SECOND
# workflow file carrying `on: push: tags: ['v*']` and a `docker push`
# therefore published with no picture gate while EVERY check in this repo --
# this one included -- stayed green. That is the cheapest bypass the repo has
# had, and it needed no edit to any file anyone was watching.
#
# The `devel-test` stage now copies the DIRECTORY, and this case asserts it
# holds exactly the files the checker above was run against. It does NOT make
# the checker read a second workflow -- limitation 1 stands -- it makes ADDING
# one a decision somebody has to take deliberately, in a red test, instead of
# a silence. Whoever adds a workflow here chooses: defend the invariant in it
# too and extend the checker, or say in this list why it cannot publish.
@test "gates: /workflows/ holds exactly the workflows the checker was run against" {
  run bash -c "find /workflows -mindepth 1 -printf '%P\n' | LC_ALL=C sort"
  assert_success
  assert_output "main.yaml"
}

# The checker is Python now, and shellcheck's `/ci/*.sh` glob cannot lint it.
# A syntax error would otherwise reach a maintainer as "exit 2 on every
# workflow", which reads like a broken input rather than a broken checker.
#
# `compile()` rather than `python3 -m py_compile`: the latter writes a
# `__pycache__` beside the source, and /ci/ is root-owned while these specs
# run as the non-root user. That is a permission error dressed as a syntax
# error -- the test would fail for a reason that has nothing to do with the
# checker. This compiles in memory and touches no filesystem.
@test "gates: the checker byte-compiles" {
  run python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
    "${CHECKER_PY}"
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
# THE MUTATIONS THE ROUND-5 (bash + awk) CHECKER DID NOT CATCH
# ==========================================================================
#
# --- root cause 1: the comment channel ------------------------------------
# normalize() stripped whole-line comments only, and six assertions were
# substring tests over raw values. A trailing `#` satisfied or evaded every
# one of them. The parser makes the channel not exist: a comment is not part
# of a value.

# The gate's work step runs `true`. The helper it is supposed to run
# survives in a trailing comment, which is all the "is there still work here"
# check was reading -- so the job ran, did nothing, reported success, and the
# image published with no picture taken.
@test "gates: the Tier B work step neutered by a trailing comment is caught" {
  _mutate 's|^        run: bash script/ci/tier_b_visual_e2e.sh$|        run: "true"  # bash script/ci/tier_b_visual_e2e.sh|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# The GPU pin defeated the same way: `self-hosted` and `gpu` are both
# still in the line, in the comment, and the gate ran on a hosted runner with
# no NVENC -- which does not slow the picture check down, it removes it.
@test "gates: the GPU pin defeated by a trailing comment is caught" {
  _mutate 's|^    runs-on: \[self-hosted, gpu\]$|    runs-on: ubuntu-latest  # was [self-hosted, gpu]|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# Both report-only jobs neutered: their condition is now `false`, and the
# `!= 'success'` the shape check looked for survives in the comment. A blocked
# release goes back to being a grey job on a green-looking run.
@test "gates: a report-only job neutered by a trailing comment is caught" {
  _mutate "s|^      && needs.tier-b-visual-e2e.result != 'success'\$|      \&\& false  # needs.tier-b-visual-e2e.result != 'success'|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[report-only-jobs-still-exist]"
}

# `steps:` with a trailing comment is not `steps:` to a line regex, so
# NOTHING below it was parsed and every step-level `if:` in publish-image
# became invisible -- here, on the step that actually pushes. The job reports
# success having published nothing, and a tag cuts a Release with no image
# behind it: the exact state this workflow's own header argues against.
@test "gates: a commented steps: hiding an if: on the push step is caught" {
  _mutate '/^  publish-image:$/,/^  tier-b-visual-e2e:$/{s|^    steps:$|    steps:  # the publish work|}' \
          '/^      - name: Build and push the runtime image$/a\        if: false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-step-is-unconditional]"
}

# A job header with a trailing comment is not a job header to a line
# regex: the job is invisible to the job list, so it is never derived as
# publishing and never required to carry the gate, while its body is silently
# attributed to the job above it. Placed directly above tier-b-visual-e2e so
# the lines it leaks land in publish-image, which is behind the gate already
# -- nothing else in the file changes its verdict, which is what made this
# silent.
@test "gates: a job header with a trailing comment is still a job" {
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

# The Tier B acceptance step is disabled outright. The job runs, the
# one step that looks at a frame does not, the job reports success, and the
# image publishes.
@test "gates: a double-quoted \"if\": on the Tier B work step is caught" {
  _mutate '/^      - name: Tier B visual acceptance/a\        "if": false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

@test "gates: a single-quoted 'if': on the Tier B work step is caught" {
  _mutate "/^      - name: Tier B visual acceptance/a\\        'if': false"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

@test "gates: a spaced 'if :' on the Tier B work step is caught" {
  _mutate '/^      - name: Tier B visual acceptance/a\        if : false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# The same three spellings at JOB level, on call-release, where the
# property is the ABSENCE of a status function. A status function there
# overrides GitHub's default skip propagation, so a skipped picture gate stops
# blocking the Release -- and the key it is written under was invisible.
@test "gates: a double-quoted \"if\": hiding a status function on call-release is caught" {
  _mutate '/^  call-release:$/,/^  publish-image:$/{s|^    if: >-$|    "if": >-|}' \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

@test "gates: a single-quoted 'if': hiding a status function on call-release is caught" {
  _mutate "/^  call-release:\$/,/^  publish-image:\$/{s|^    if: >-\$|    'if': >-|}" \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

@test "gates: a spaced 'if :' hiding a status function on call-release is caught" {
  _mutate '/^  call-release:$/,/^  publish-image:$/{s|^    if: >-$|    if : >-|}' \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# The same at job level on verify-tag-shape, where ANY job-level `if:`
# is forbidden -- it is a need of the picture gate, and a skipped need skips
# its dependent, so this job must always run.
@test "gates: a double-quoted \"if\": on verify-tag-shape is caught" {
  _mutate '/^  verify-tag-shape:$/a\    "if": false'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[verify-tag-shape-has-no-job-level-if]"
}

@test "gates: a spaced 'if :' on verify-tag-shape is caught" {
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

# An unbalanced `(` inside a string pins depth ABOVE zero, so the `||`
# appended after it is invisible and the whole gate chain becomes one
# alternative of a disjunction.
@test "gates: a '(' inside a string hiding a top-level || is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      \&\& !contains(github.ref_name, '(')\n      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# The same in the other direction: a `)` inside a string drives depth
# BELOW zero, with the same effect and from the opposite side.
@test "gates: a ')' inside a string hiding a top-level || is caught" {
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

# A publishing command split across a folded scalar never appears
# contiguously in the raw text, so a substring search over the job body could
# not find it and the job was never derived as one that publishes. The parser
# folds the scalar before anything looks at it.
@test "gates: a publishing command folded across lines is still publishing" {
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

# `permissions: write-all` is one token and grants every scope there is.
@test "gates: permissions: write-all is a publishing job" {
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

# A workflow-level `permissions:` block is the grant every job WITHOUT its
# own block runs with. Reading only job-level blocks meant a workflow that
# handed write to everything looked read-only.
@test "gates: a workflow-level permissions grant reaches every job" {
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

# `docker buildx build --push` names neither `docker push` nor
# `push: true`, which were the two docker spellings on the list.
@test "gates: docker buildx build --push is publishing" {
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

# `push:` with an expression value could be true on any run; the list held
# the literal `push: true`.
@test "gates: push: with an expression value is publishing" {
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

# `!failure()` is true in a cancelled run, exactly like `always()`. The
# round-5 check tested for the literal `always(`, so the same escape under
# another name walked through -- and a cancelled Tier B, evicted from the GPU
# concurrency group as a pending member, is a documented case here.
@test "gates: !failure() in place of publish-image's !cancelled() is caught" {
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
# LEGAL EDITS THE ROUND-5 CHECKER REPORTED AS VIOLATIONS
# ==========================================================================
#
# A checker that reports a correct edit as a violation is not merely noisy: it
# teaches maintainers that the gate is noise, and a gate people have learned
# to route around is how a real violation gets waved past next time. Each of
# these was a false positive; each is paired above or below with a case
# proving the acceptance did not widen into a blanket pass.

# `continue-on-error: false` is the DEFAULT written out loud. The check
# was a substring search for the word.
@test "gates: continue-on-error: false is not a violation" {
  _mutate '/^  tier-b-visual-e2e:$/a\    continue-on-error: false'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# A trailing comment after a needs list was split on whitespace along with
# the list, and the words in it were reported as jobs that do not exist ("#",
# "the", "picture", "gate").
@test "gates: a trailing comment after needs: is not four missing jobs" {
  _mutate 's|^    needs: \[call-docker-build, call-release, tier-b-visual-e2e\]$|    needs: [call-docker-build, call-release, tier-b-visual-e2e]  # the picture gate|'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# `'on':` is the YAML-1.1-safe spelling of the trigger key -- YAML 1.1
# resolves a bare `on` to the boolean true, which is why the quoted form
# exists. Reading only the bare spelling reported a workflow with no triggers
# at all.
@test "gates: the quoted 'on': trigger key is read" {
  _mutate "3s|^on:\$|'on':|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# Expressions were compared as strings against literal spellings, so the
# optional whitespace was load-bearing: `result=='success'` and
# `startsWith(github.ref,'refs/tags/')` are the same expressions the workflow
# already contains, written without spaces GitHub does not require.
@test "gates: equivalent expressions without optional whitespace pass" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& needs.tier-b-visual-e2e.result=='success'#" \
          "s#^      || startsWith(github.ref, 'refs/tags/')\$#      || startsWith(github.ref,'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ... and the pairing that stops the whitespace-insensitivity widening into
# "any expression containing the right words": the same spelling with the
# operand changed is still caught.
@test "gates: whitespace insensitivity does not accept a different expression" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& needs.tier-b-visual-e2e.result=='failure'#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-requires-tier-b-success]"
}

# ==========================================================================
# THE MUTATIONS THE ROUND-6 (PyYAML) CHECKER DID NOT CATCH
# ==========================================================================
#
# Round 6's parse closed 28 of 35 live bypasses. A reviewer then landed 39
# fresh mutations against it and 15 still walked through. They fall into five
# groups, and none of them is a mistake in an individual rule either -- they
# are, again, properties of HOW the questions were asked.

# --- root cause 6: case-sensitive matching of a case-insensitive language --
#
# GitHub expression function names are case-insensitive. The round-6 checker
# matched `\balways\s*\(` case-SENSITIVELY, so `if: ALWAYS()` on call-release
# was invisible to the one property whose whole job is to keep a status
# function OFF that job -- and the absence of a status function there is what
# keeps GitHub's default skip propagation in force, which is what makes an
# unavailable GPU runner block the release.
#
# Paired with a work step that cannot fail, that is the entire invariant
# defeated by two capital letters, and the round-6 checker printed "holds the
# release invariant" for it.
@test "gates: ALWAYS() on call-release is a status function like any other" {
  _mutate "s#^      startsWith(github.ref, 'refs/tags/')\$#      ALWAYS() \&\& startsWith(github.ref, 'refs/tags/')#" \
          "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: Always() in mixed case is a status function like any other" {
  _mutate "s#^      startsWith(github.ref, 'refs/tags/')\$#      Always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# The same root cause pointed the other way, at publish-image, where the
# property is "the ONLY status function here is the narrow !cancelled()".
@test "gates: ALWAYS() in place of publish-image's !cancelled() is caught" {
  _mutate 's/^      !cancelled()$/      ALWAYS()/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-status-function-is-narrow]"
}

# ... and the acceptance half, which is the reason case-sensitivity was worth
# fixing rather than working around: it failed OPEN for the spelling an
# attacker wants and CLOSED for one a maintainer might legitimately write.
# `STARTSWITH(GitHub.ref, ...)` is the same tag-ref test the workflow already
# has, and reporting it as a violation is a false positive.
@test "gates: STARTSWITH in capitals is still the tag-ref test" {
  _mutate "s@startsWith(github.ref, 'refs/tags/')@STARTSWITH(GitHub.ref, 'refs/tags/')@g"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

@test "gates: !CANCELLED() in capitals is still the narrow status test" {
  _mutate 's/^      !cancelled()$/      !CANCELLED()/'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# --- root cause 7: the gate's work identified by COUNTING, not by identity -
#
# `gate-job-work-step-is-unconditional` counted steps whose text names
# something under `script/ci/` and required them unconditional. That question
# cannot tell tier_b_visual_e2e.sh from derive_image_tag.sh, and it cannot
# tell the driver from the driver with `|| true` after it. Eight bypasses
# followed, every one of them publishing an image for a commit whose picture
# was never taken while the job reported success.
#
# The answer is not a longer count. It is `gate-job-runs-its-driver-verbatim`:
# THIS command runs, unconditionally, and nothing else in the job invokes the
# same script in another spelling. See GATE_WORK_DRIVERS.

@test "gates: the Tier B driver suffixed with || true is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: the Tier B driver reduced to --help is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh --help@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: the Tier B driver reduced to --version is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh --version@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: the Tier B driver wrapped in set +e and exit 0 is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: set +e; bash script/ci/tier_b_visual_e2e.sh; exit 0@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# The count could not tell one script/ci/ helper from another, so pointing the
# picture gate's work step at the tag deriver satisfied it exactly.
@test "gates: the Tier B work step pointed at a different helper is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/derive_image_tag.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# The decoy family. In each of the three below an UNCONDITIONAL step naming
# `script/ci/` keeps the old count satisfied while the thing that would
# actually look at a frame moves behind an `if:` that is never true -- as
# `run: $CMD` with the command in `env:`, as a third-party action, and as a
# plain inline `run:`.
@test "gates: an echo decoy plus the real work behind env indirection is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: echo 'the driver lives under script/ci/'\n        env:\n          CMD: bash script/ci/tier_b_visual_e2e.sh\n      - name: The real work, behind a condition\n        if: \${{ github.event_name == 'never' }}\n        run: eval \"\$CMD\"@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: an echo decoy plus a guarded third-party action is caught" {
  _mutate "s#^        run: bash script/ci/tier_b_visual_e2e.sh\$#        run: echo 'see script/ci/ for what this used to do'\n      - name: The real work, behind a condition\n        if: \${{ github.event_name == 'never' }}\n        uses: some/visual-acceptance-action@v1#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: an echo decoy plus a guarded inline run is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: echo 'see script/ci/ for what this used to do'\n      - name: The real work, behind a condition\n        if: \${{ github.event_name == 'never' }}\n        run: ./take-the-picture.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# The same pin on the OTHER driver job. verify-tag-shape runs the deriver
# before anything irreversible happens; `|| true` there lets a tag the
# deriver cannot publish reach the GPU gate and the Release.
@test "gates: the tag deriver suffixed with || true is caught" {
  _mutate "s@^        run: bash script/ci/derive_image_tag.sh\$@        run: bash script/ci/derive_image_tag.sh || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# A `--print-<x>` QUERY is the one other spelling the job may contain -- this
# repo pulls the producer image the driver names -- and it must be
# unconditional too: a skipped query fails the step that consumes it.
@test "gates: an if: on the driver's --print- query is caught" {
  _mutate "s|^        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"\$|        if: \${{ github.event_name == 'never' }}\n        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# ... and the acceptance half, so "exact" does not mean "byte-identical".
# Whitespace inside the command is not meaning; an ARGUMENT is, which is why
# every case above is a violation and this one is not.
@test "gates: extra whitespace inside the driver invocation still passes" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash   script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# --- root cause 7b: the driver was pinned as a STRING, not as an INVOCATION -
#
# `gate-job-runs-its-driver-verbatim` compared the collapsed `run:` text to
# one command. FOUR SIBLING KEYS decide what that string actually does, and
# the checker read none of them -- so six mutations published with no picture
# while it printed "holds the release invariant", and in three of them the
# PINNED LINE IS UNTOUCHED and the diff shows only a `defaults:` block.
#
# The answer is `gate-driver-runs-unmodified`: on a step that invokes one of
# GATE_WORK_DRIVERS, `shell:`, `working-directory:` and `env:` are refused;
# and `defaults.run` and `env:` are refused at job level on those jobs and at
# workflow level, where they reach them. The acceptance cases below bound
# that: the same keys elsewhere in the same file are not violations.

# GitHub's documented custom-shell form is `command [...options] {0}`, so the
# driver is PRINTED and never runs, while the step and the job report success.
@test "gates: shell: cat {0} on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        shell: cat {0}\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The same hole spelled as something that reads like a lint tweak in review.
@test "gates: shell: bash -n {0} on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        shell: bash -n {0}\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The verbatim string, resolved against another tree -- a fixture holding a
# stub of the same path.
@test "gates: working-directory: on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        working-directory: test/fixtures/stub-tree\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The driver reads TIER_B_PRODUCER_IMAGE, TIER_B_VIEWER_IMAGE and
# TIER_B_BOOT_TIMEOUT from its environment (script/ci/tier_b_visual_e2e.sh),
# so a step-level env: makes the "picture" one of whatever image the editor
# chose -- with the pinned line, and the gate's own name, intact.
@test "gates: env: on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        env:\n          TIER_B_PRODUCER_IMAGE: ghcr.io/somewhere/else:latest\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# ... and the same variable one level up, which no step-level rule can see.
@test "gates: a job-level env: on the picture gate is caught" {
  _mutate "s@^    runs-on: \[self-hosted, gpu\]\$@    runs-on: [self-hosted, gpu]\n    env:\n      TIER_B_PRODUCER_IMAGE: ghcr.io/somewhere/else:latest@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# ... and two levels up, where it reaches every job in the file including
# this one.
@test "gates: a workflow-level env: reaching the picture gate is caught" {
  _mutate "s@^jobs:\$@env:\n  TIER_B_PRODUCER_IMAGE: ghcr.io/somewhere/else:latest\njobs:@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# THE THREE THAT NEVER TOUCH THE PINNED LINE. A reviewer reading the diff
# sees a `defaults:` block and a `run:` line that still says exactly what it
# always said.
@test "gates: a job-level defaults.run.shell on the picture gate is caught" {
  _mutate "s@^    runs-on: \[self-hosted, gpu\]\$@    runs-on: [self-hosted, gpu]\n    defaults:\n      run:\n        shell: cat {0}@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: a workflow-level defaults.run.shell is caught" {
  _mutate "s@^jobs:\$@defaults:\n  run:\n    shell: cat {0}\njobs:@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: a workflow-level defaults.run.working-directory is caught" {
  _mutate "s@^jobs:\$@defaults:\n  run:\n    working-directory: test/fixtures/stub-tree\njobs:@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# --- root cause 7c: clause (c) was a SUBSTRING test ------------------------
#
# `if "--print-" in run and not step_if: continue` granted ANY unconditional
# step containing that literal a free pass to invoke the driver in any
# spelling. There is a case for an unconditional, GENUINE `--print-<x>`
# query -- this repo pulls the producer image the driver names -- and none
# for a decoy that merely carries the substring somewhere in the same body
# while invoking the driver as `--help`.
@test "gates: a --print- decoy carrying a --help invocation is caught" {
  _mutate "s@^        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"\$@        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"\n      - name: Warm the driver up\n        run: echo --print-nothing \&\& bash script/ci/tier_b_visual_e2e.sh --help || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# --- the acceptance half of all of the above ------------------------------
#
# Each refusal above is bounded by a case proving it did not become a blanket
# ban on the key. Without these, "no shell:, no env:, no defaults:" would be
# a rule about the whole workflow rather than about the two pinned drivers.

# A SECOND genuine query is still a query. This is the acceptance pair for
# the decoy case above: what makes that one a violation is the `--help`
# invocation, not the presence of a second step.
@test "gates: a second genuine --print- query on the driver still passes" {
  _mutate "s@^        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"\$@        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"\n      - name: Record the producer this run will use\n        run: echo \"producer=\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\" >> \"\${GITHUB_STEP_SUMMARY}\"@"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# An env: on a step of the gate job that does NOT invoke the driver cannot
# change what the driver does: it is a different process.
@test "gates: env: on a non-driver step of the gate job still passes" {
  _mutate "s@^        run: ./script/build.sh -t e2e-test\$@        env:\n          DOCKER_BUILDKIT: '1'\n        run: ./script/build.sh -t e2e-test@"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# `defaults:` on a job that runs no pinned driver is an ordinary edit. The
# refusal is scoped to the two GATE_WORK_DRIVERS jobs and to the workflow
# level, which reaches them.
@test "gates: defaults.run.shell on a job with no pinned driver still passes" {
  _mutate "s@^  publish-image:\$@  publish-image:\n    defaults:\n      run:\n        shell: bash@"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# --- root cause 8: shell-comment stripping applied to PUBLISHING ----------
#
# `_strip_shell_comments` ends a line at a whitespace-preceded `#`. That is
# the right approximation for recognising gate WORK (a commented-out helper
# is not work) and exactly the wrong one for deriving PUBLISHING, where
# losing the signal means the job is never required to stand behind the gate
# at all. A `#` inside a double-quoted shell string is not a comment to the
# shell, and it swallowed the push that followed it.
#
# Publishing is now derived from the RAW `run:` body. The trade is stated in
# limitation 4: a genuinely commented-out `docker push` marks the job as one
# that must stand behind the gate, which costs a `needs:` line.
@test "gates: a # inside a shell string does not hide the docker push after it" {
  _append_job <<'JOB'
  publish-after-echo:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: |
          echo "build #1 done" ; docker push ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-after-echo"
}

@test "gates: a # inside a shell string does not hide the gh release after it" {
  _append_job <<'JOB'
  release-after-echo:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: |
          echo "build #1 done" ; gh release create v1.2.3
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "release-after-echo"
}

# --- root cause 9: PUBLISH_RUN_RE is an enumeration -----------------------
#
# Four more spellings the round-6 table did not hold, and one -- a shell line
# continuation -- that defeated EVERY row at once rather than one of them,
# because each pattern matches within a single line. Continuations are joined
# before matching now. The enumeration still does not converge, and
# limitation 4 says so in those words.
@test "gates: docker image push is publishing" {
  _append_job <<'JOB'
  publish-image-subcommand:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: docker image push ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-image-subcommand"
}

# `regctl` had a ROW IN THE TABLE THAT MATCHED NOTHING REAL: the pattern was
# `regctl (push|copy)`, and regctl has neither subcommand -- the real spelling
# is `regctl image copy`. A row that looks like coverage and provides none is
# worse than an admitted gap, because the name appearing in the table is what
# stops anyone checking.
@test "gates: regctl image copy is publishing" {
  _append_job <<'JOB'
  publish-regctl:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: regctl image copy ghcr.io/x/y:z ghcr.io/x/y:latest
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-regctl"
}

@test "gates: regctl artifact put is publishing" {
  _append_job <<'JOB'
  publish-regctl-artifact:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: regctl artifact put --artifact-type application/x ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-regctl-artifact"
}

# A registry login in a job that publishes nothing is not a normal pattern
# -- the same reasoning that puts docker/login-action in PUBLISH_USES rather
# than leaving it to whichever spelling the push happens to use. Added with
# the row it tests, because a row nothing exercises is precisely the failure
# the two cases above exist to correct.
@test "gates: regctl registry login is publishing" {
  _append_job <<'JOB'
  login-regctl:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Log in
        run: regctl registry login ghcr.io
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "login-regctl"
}

# ... and the acceptance half: a regctl READ is not a publish. Without this,
# widening the row to `regctl <anything>` would report every registry query
# as a job that must stand behind the picture gate.
@test "gates: regctl image digest is not publishing" {
  _append_job <<'JOB'
  inspect-regctl:
    runs-on: ubuntu-latest
    steps:
      - name: Look
        run: regctl image digest ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

@test "gates: buildah push is publishing" {
  _append_job <<'JOB'
  publish-buildah:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: buildah push ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-buildah"
}

@test "gates: podman push is publishing" {
  _append_job <<'JOB'
  publish-podman:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: podman push ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-podman"
}

@test "gates: a REST write to the releases API is publishing" {
  _append_job <<'JOB'
  publish-rest:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: gh api -X POST /repos/o/w/releases -f tag_name=v1.2.3
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-rest"
}

@test "gates: a push split by a shell line continuation is still publishing" {
  _append_job <<'JOB'
  publish-continued:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        run: |
          docker \
            push ghcr.io/x/y:z
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-continued"
}

# --- root cause 10: env: indirection --------------------------------------
#
# `step_text()` read `run` and `uses` only, so a command written as an `env:`
# value and reached with `eval "$CMD"` was invisible. `env:` values are now
# searched for publishing signals -- deliberately, and only for publishing:
# see publish_search_text.
@test "gates: a push written as an env value is still publishing" {
  _append_job <<'JOB'
  publish-indirect:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Ship
        env:
          CMD: docker push ghcr.io/x/y:z
        run: eval "$CMD"
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-indirect"
}

# Job-level `env:` is read too, and reported as the JOB's rather than as some
# arbitrary step's -- a command written twenty lines above the steps would
# otherwise send a maintainer to the wrong place.
@test "gates: a push written as a job-level env value is still publishing" {
  _append_job <<'JOB'
  publish-indirect-job-env:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    env:
      CMD: docker push ghcr.io/x/y:z
    steps:
      - name: Ship
        run: eval "$CMD"
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publishing-job-is-behind-the-picture-gate]"
  assert_output --partial "publish-indirect-job-env"
  assert_output --partial "job-level env CMD"
}

# ... and the acceptance half of the widened table, which matters here more
# than anywhere else: this repo's own publish-image READS
# `/repos/<r>/releases/tags/v<version>` from behind an `if:`, to refuse a
# publish with no Release behind it. Deriving that GET as "the publishing
# act" would report the guard itself as a violation, so the REST pattern is
# scoped to an explicit write method.
@test "gates: a GET against the releases API is not publishing" {
  _append_job <<'JOB'
  read-only-release-probe:
    needs: [call-docker-build]
    runs-on: ubuntu-latest
    steps:
      - name: Look
        run: gh api /repos/o/w/releases/tags/v1.2.3
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# --- root cause 11: trigger PRESENCE re-read as trigger REACHABILITY ------
#
# `glob_to_regex()` had no `!` case, so a NEGATIVE tag pattern was compiled as
# a literal one and matched nothing -- which meant appending
# `- '!v[0-9]+.[0-9]+.[0-9]+-*'` silently excluded every release candidate
# while the property whose own comment reads PRESENCE IS NOT REACHABILITY
# passed. The incident this whole file exists for (#70) was an rc.
@test "gates: a negative tag glob that excludes every rc is caught" {
  _mutate "s|^      - 'v\[0-9\]+.\[0-9\]+.\[0-9\]+-\*'\$|      - 'v[0-9]+.[0-9]+.[0-9]+-*'\n      - '!v[0-9]+.[0-9]+.[0-9]+-*'|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-globs-match-a-real-version]"
}

# ... and the acceptance half, so honouring `!` does not become "any `!` is a
# violation": a negation that excludes something this repo never cuts leaves
# both probe tags reachable.
@test "gates: a negation that excludes no real version still passes" {
  _mutate "s|^      - 'v\[0-9\]+.\[0-9\]+.\[0-9\]+-\*'\$|      - 'v[0-9]+.[0-9]+.[0-9]+-*'\n      - '!vnope[0-9]'|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# A `paths:` filter on the same `push:` trigger is refused rather than
# evaluated. Whether GitHub applies one to a TAG push is not settled from the
# workflow text, and under the reading that matters an unmatchable filter
# silences every tag push while the tag patterns still look right.
@test "gates: a paths filter on the tag trigger is refused" {
  _mutate "s|^  pull_request:\$|    paths:\n      - 'does/not/exist/**'\n  pull_request:|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-trigger-has-no-path-filter]"
  # The RULE is right and fails closed. The REMEDY was not achievable:
  # "split the tag trigger into its own `on.push` entry" describes a second
  # `on.push` key, which is a duplicate key -- refused here and by GitHub.
  # A remedy an operator cannot carry out discounts the true thing the
  # message says next, which is the same failure the entrypoint's flat-key
  # diagnostics were rewritten for.
  refute_output --partial "into its own"
  assert_output --partial "drop the 'paths:' filter from on.push entirely"
  assert_output --partial "no second 'on.push' to split into"
}

# --- root cause 12: runs-on read in two of its four shapes ----------------
#
# `as_list()` on a `runs-on:` MAPPING yields `str(dict)`, so the documented
# `{group:, labels:}` syntax -- what the org will write the day the GPU host
# moves into a runner group -- was reported as a gate that had left the GPU.
# So was a matrix-driven `runs-on`. A check that reports valid edits as
# violations is one people learn to switch off.
# GitHub matches runner LABELS case-insensitively, and this file matched them
# case-sensitively while matching expressions case-insensitively -- the exact
# inconsistency the expression change argued against, one round earlier. It
# failed CLOSED (a correct edit reported as a violation), so it was noise
# rather than a hole; noise is still how a check gets switched off.
@test "gates: runner labels in mixed case are the same runner" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: [Self-Hosted, GPU]|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ... and its failing half, so case-insensitivity did not become "any label
# set will do": the GPU label still has to be there, in some case.
@test "gates: a mixed-case label set that has lost the GPU is still caught" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: [Self-Hosted, Ubuntu-Latest]|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

@test "gates: a runner group that still declares the labels passes" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: {group: gpu-hosts, labels: [self-hosted, gpu]}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

@test "gates: a matrix whose every runner is the GPU runner passes" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    strategy:\n      matrix:\n        runner: [[self-hosted, gpu]]\n    runs-on: \${{ matrix.runner }}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ... and the three failing halves, so neither acceptance widens into a
# blanket pass. A group with NO labels is not resolvable here (which machines
# are in a group is a repo setting, limitation 6); a matrix with one hosted
# entry runs the gate off the GPU for that entry; an expression from outside
# the file is not determined here at all.
@test "gates: a runner group with no labels is not proof of a GPU runner" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: {group: gpu-hosts}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

@test "gates: a matrix with one hosted runner is caught" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    strategy:\n      matrix:\n        runner: [[self-hosted, gpu], [ubuntu-latest]]\n    runs-on: \${{ matrix.runner }}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

@test "gates: a runs-on expression from outside this file is caught" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: \${{ inputs.runner }}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# ==========================================================================
# NO SILENT EXIT
# ==========================================================================
#
# The awk implementation this replaced could die with status 141 and NO
# OUTPUT AT ALL -- a SIGPIPE between two of its own helpers, deterministic on
# the leaked-job input below. A checker that says nothing and exits non-zero teaches a
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
