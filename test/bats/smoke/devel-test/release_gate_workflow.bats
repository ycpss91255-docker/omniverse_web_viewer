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
  # A writable copy of the whole workflows DIRECTORY, for the cases that ask
  # what happens when a second workflow exists. /workflows is read-only in
  # the image and one file is no longer the unit of analysis.
  WORKFLOW_DIR="${TMP}/workflows"
  mkdir -p "${WORKFLOW_DIR}"
  cp "${WORKFLOW}" "${WORKFLOW_DIR}/main.yaml"
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


# _sibling_workflow <name> <yaml> -- drop another workflow next to main.yaml
# in the writable copy, so a case can ask what the checker does with two.
_sibling_workflow() {
  printf '%s\n' "$2" > "${WORKFLOW_DIR}/$1"
}

# why: Structural lock on the RELEASE INVARIANT, read off
# `.github/workflows/main.yaml` itself. The rule (#70, after `v0.3.0-rc1`
# published with no picture ever verified for it) is absolute: no version
# may publish without the Tier B picture gate having passed on that commit
# -- no override, no `continue-on-error`, no status-function escape, and an
# unavailable GPU runner BLOCKS the release. Until this file existed that
# rule was defended by prose: it lived in `if:` / `needs:` expressions and
# comments in one workflow and nothing read them, so `|| github.event_name
# == 'workflow_dispatch'` added to a gate while debugging, or
# `tier-b-visual-e2e` dropped from a `needs:` list, left every other gate
# green with the protection gone. The reading is done by
# `script/ci/check_release_gates.py`, a real YAML parse (PyYAML), fronted by
# `script/ci/check_release_gates.sh`, which verifies the one dependency out
# loud and refuses with exit 2 -- never a skip -- when `python3` or PyYAML
# is missing. PyYAML is added by the `devel-test` Dockerfile stage as
# `python3-yaml` and never ships: `runtime` is `FROM devel-base`,
# `devel-test` is `FROM devel`, and nothing is `FROM devel-test`. The
# workflow is `COPY`d to `/workflows/main.yaml` and `script/ci/` to `/ci/`,
# the same mechanism the other specs use for their inputs. No GPU, no tag
# push, no GitHub, no network: it runs on every PR. **Why a parser and not a
# grep.** The first version of this spec claimed the invariant and did not
# deliver it: property 2 was a substring test, so the very `||` the sentence
# above names walked past it. An independent reviewer wrote 23 mutations the
# author had not anticipated and 12 were not caught, four of which publish
# or release with no picture verified while all fourteen tests stayed green.
# What changed then: `needs:` is read as a LIST and matched by membership (a
# decoy job merely NAMED after the gate no longer satisfies it); a
# requirement is a MANDATORY TOP-LEVEL CONJUNCT rather than a substring (a
# gate wrapped into a `||`, or one `||` appended to the end of a whole
# condition, is caught); STEP level is examined, so a gate job whose work
# step is skipped is no longer a passed gate; the set of jobs that must
# carry the gate is DERIVED from the file rather than listed by name; the
# GPU runner, the report-only jobs and the tag globs' ability to match a
# real version are asserted; and two semantically equivalent spellings that
# were reported as violations are now accepted, because a gate that cries
# wolf on a correct edit teaches maintainers to route around it. That
# hardening was 885 lines of bash and awk, and a reviewer landed 21 more
# mutations past it -- four of which removed the picture gate entirely while
# the checker printed "holds the release invariant". Almost none of the 21
# were mistakes in an individual rule; they were properties of reading YAML
# with line regexes: (a) trailing comments, since stripping whole-line
# comments and then testing substrings over raw values means one `#`
# satisfies or evades the check; (b) `if:` / `"if":` / `'if':` / `if :`
# being four YAML spellings of one key, at step level AND at job level, in
# both places where ABSENCE is what the property asserts; (c) parenthesis
# counting that was not string-literal aware, so one `(` inside a quoted
# string pinned depth off zero and hid every top-level operator after it;
# (d) a job header with a trailing comment not being a job header, its body
# silently attributed to the job above it. A real parser answers (a), (b)
# and (d) outright and reduces (c) to one tokeniser the checker owns. A real
# parser closed 28 of 35 live bypasses. A third reviewer then landed 39
# fresh mutations against THAT and 15 still walked through, in five groups:
# (e) case-sensitive matching of a case-INSENSITIVE language, so `if:
# ALWAYS()` on `call-release` was invisible to the one property that keeps a
# status function off that job -- paired with a work step suffixed `||
# true`, the entire invariant, defeated by two capital letters, while the
# checker printed "holds the release invariant"; (f) the gate's work
# identified by COUNTING steps that name something under `script/ci/` rather
# than by IDENTITY, so `|| true`, `--help`, `--version`, a `set +e; ...;
# exit 0` wrapper, a different helper entirely, and three flavours of
# unconditional decoy beside a guarded real work step all satisfied the
# count with no picture taken; (g) shell-comment stripping applied when
# DERIVING publishing, where losing the signal means the job is never
# required to stand behind the gate at all -- a `#` inside a double-quoted
# shell string swallowed the `docker push` after it; (h) `PUBLISH_RUN_RE`
# being an enumeration (`docker image push`, `buildah push`, `podman push`,
# `gh api -X POST .../releases`, and a shell line continuation that defeated
# every row at once); (i) questions asked in one shape of a construct that
# has four -- a `!`-negated tag glob compiled as a literal, a `paths:`
# filter never considered, a `runs-on:` runner-group mapping and a
# matrix-driven `runs-on` both reported as valid edits gone wrong. **Case
# names below describe what each case DOES.** They used to carry a
# reviewer's identifiers, reconstructed from a brief rather than from the
# review's corpus; a later reviewer who had the corpus found 24 of 25
# sitting on a different mutation than the one they claimed, five of them on
# green cases whose named bypass was still live. The labels and the claim
# that went with them are deleted rather than repaired. **What the checker
# cannot see** is stated in exactly one place: the `WHAT THIS CANNOT SEE`
# section of `script/ci/check_release_gates.py`'s header, twelve numbered
# items. It names in those words what survives this round: the gate's work
# can still be a NO-OP in any job other than the two whose driver is pinned
# by identity; `PUBLISH_RUN_RE` is an enumeration that does not converge;
# the checker still reads ONE workflow file, now loudly rather than silently
# (the stage copies the directory and a case asserts its contents, so a
# second workflow is a red test, but nothing reads it); and four things
# around the pinned drivers are named there one by one, including a step
# that prepares the ground for a later step without naming the driver, and
# `container:` / `services:` on the job. It is not restated here, and this
# section is not the place to look it up -- four restatements in four
# documents is precisely how that list drifted into four different lists,
# none of which named the comment channel, the single most productive attack
# in the last review. The list is deliberately narrow, because an
# over-claimed gate is worse than a narrow one: it stops people looking.
# Every property is proved TWICE -- once against the shipped workflow (it
# must hold) and once against a copy with that one property removed (the
# checker must name its `[id]`). An assertion that cannot fail is the
# failure this repo has been bitten by three times, so `_mutate` hard-fails
# when its `sed` matches nothing rather than asserting against an unmodified
# file. Twenty-six cases assert the checker SUCCEEDS -- on semantically
# identical rewrites, and on legal edits an earlier version reported as
# violations -- and each is paired with a failing case in the same spelling
# so the acceptance cannot widen into a blanket pass.


# why: The spec is worthless if either input is missing; the wrapper, the
# Python checker and the workflow are all asserted
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
# The assertion that used to stand here -- "find /workflows must equal exactly
# main.yaml" -- is gone, not weakened. It was never about the workflow set; it
# was a stand-in for an analysis that did not exist, back when the checker read
# one file and everything beside it was unexamined territory. The checker now
# reads the whole directory and asks each workflow whether it can publish, so
# counting files answers a question nobody is asking. A spec whose premise has
# gone is worse than none: it passes for the wrong reason, or fails for the
# right one and gets "fixed".

# The checker is Python now, and shellcheck's `/ci/*.sh` glob cannot lint it.
# A syntax error would otherwise reach a maintainer as "exit 2 on every
# workflow", which reads like a broken input rather than a broken checker.
#
# `compile()` rather than `python3 -m py_compile`: the latter writes a
# `__pycache__` beside the source, and /ci/ is root-owned while these specs
# run as the non-root user. That is a permission error dressed as a syntax
# error -- the test would fail for a reason that has nothing to do with the
# checker. This compiles in memory and touches no filesystem.
# why: The checker is Python now and shellcheck's `/ci/*.sh` glob cannot
# lint it. A syntax error would otherwise reach a maintainer as "exit 2 on
# every workflow", which reads like a broken input rather than a broken
# checker
@test "gates: the checker byte-compiles" {
  run python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
    "${CHECKER_PY}"
  assert_success
}

# The one dependency, asserted in the image that is supposed to have it. The
# `devel-test` stage installs python3-yaml; nothing shipped is FROM this
# stage, so this is also the assertion that the install landed where it was
# meant to.
# why: The one dependency, asserted in the image that is supposed to have
# it. `devel-test` installs `python3-yaml` and nothing is `FROM devel-test`,
# so this is also the proof the install landed where it was meant to
@test "gates: the image the checker runs in has PyYAML" {
  run python3 -c 'import yaml; print(yaml.__version__)'
  assert_success
}

# why: Every property holds on `main.yaml` as committed
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
# why: Vacuity guard: a checker that "passes" on a file it never read
# reports an invariant that protects nothing (exit 2, distinct from a
# violation's exit 1)
@test "gates: a workflow that cannot be read is an error, not a pass" {
  run bash "${CHECK}" "${TMP}/does-not-exist.yaml"
  assert_failure 2
  assert_output --partial "cannot read workflow"
}

# why: Same guard for a file whose jobs are gone (exit 2)
@test "gates: a workflow with no jobs is an error, not a vacuous pass" {
  printf 'name: Empty\non:\n  push:\njobs:\n' > "${TMP}/empty.yaml"
  run bash "${CHECK}" "${TMP}/empty.yaml"
  assert_failure 2
  assert_output --partial "declares no jobs"
}

# New with the parser: a file that is not YAML at all used to be read line by
# line and reported on regardless.
# why: New with the parser: a file that is not YAML at all used to be read
# line by line and reported on regardless (exit 2)
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
# why: A duplicate key is last-wins in PyYAML and rejected by GitHub, so a
# job with `if:` twice is one condition to the checker and another to the
# maintainer reading top to bottom -- and the disagreement is invisible both
# ways (exit 2)
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
# why: The dependency check is a REFUSAL. A checker that quietly does
# nothing when its parser is missing is the silent green board this file
# exists to end, so the path is exercised with a `python3` that cannot
# import it -- exit 2, saying "NOT verified"
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

# why: `[publish-image-needs-tier-b]` -- an image pushed for a commit whose
# picture was never verified
@test "gates: dropping tier-b from publish-image's needs is caught" {
  _mutate 's/needs: \[call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence\]/needs: [call-docker-build, call-release, require-picture-evidence]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-needs-tier-b]"
}

# publish-image's condition opens with `!cancelled()`, which it needs because
# call-release is legitimately skipped on both dispatch paths. That status
# function also stops a SKIPPED need from skipping this job -- so the explicit
# `result == 'success'` is the only thing left blocking an image whose picture
# gate never ran.
# why: `[publish-image-requires-tier-b-success]` -- its `!cancelled()` means
# a SKIPPED gate no longer skips the job, so the explicit `result ==
# 'success'` is the only thing left blocking the push
@test "gates: dropping publish-image's tier-b success requirement is caught" {
  _mutate '/&& needs\.tier-b-visual-e2e\.result == /d'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-requires-tier-b-success]"
}

# M1: the requirement is still THERE, character for character, but it is now
# one alternative of a disjunction -- a hand-typed publish_image_tag satisfies
# it with the gate skipped, failed, or never run.
# why: **M1**, uncaught before: `(needs.tier-b-visual-e2e.result ==
# 'success' || inputs.publish_image_tag != '')`. The required string is
# present character for character, but it is now an ALTERNATIVE a hand-typed
# tag satisfies on its own. The check is a top-level `&&` term, not a
# substring
@test "gates: the tier-b success requirement demoted to an alternative is caught" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& (needs.tier-b-visual-e2e.result == 'success' || inputs.publish_image_tag != '')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-requires-tier-b-success]"
}

# M55: nothing is removed and nothing is wrapped -- one `||` is appended to the
# END of the condition. `&&` binds tighter than `||`, so the whole gate chain
# collapses into one side of a disjunction and the other side publishes alone.
# why: **M55**, uncaught before: `[publish-image-gate-is-not-optional]`.
# Nothing removed, nothing wrapped -- one `||` at the END. `&&` binds
# tighter, so the whole gate chain becomes one side of a disjunction and the
# other side publishes alone
@test "gates: a top-level || appended to publish-image's whole condition is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# ---------------------------------------------------------------- release --

# why: `[call-release-needs-tier-b]` -- a Release cut for a commit whose
# picture was never verified
@test "gates: dropping tier-b from call-release's needs is caught" {
  _mutate 's/needs: \[verify-tag-shape, verify-tag-on-main, call-docker-build, tier-b-visual-e2e, require-picture-evidence\]/needs: [verify-tag-shape, verify-tag-on-main, call-docker-build, require-picture-evidence]/'
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
# why: `[call-release-carries-no-status-function]` -- the load-bearing
# ABSENCE: with no `always()` / `success()` / `failure()` / `cancelled()`,
# GitHub's default skip propagation applies, and that default is the whole
# mechanism by which an unavailable GPU runner blocks a release
@test "gates: adding a status function to call-release's if is caught" {
  _mutate "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# ------------------------------------------------------------------ gates --

# why: `[gate-job-has-no-continue-on-error]` -- turns a gate into a
# suggestion, at job or step level, on the named gate jobs AND on every
# derived publishing job
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
# why: `[gate-job-is-defined]` -- a new id, split out because a missing gate
# job used to be reported under `[gate-job-has-no-continue-on-error]`, which
# is not what happened: the job is absent, and it has no `continue-on-error`
# precisely because it has nothing. That message sends a maintainer looking
# for a flag that is not there
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
# why: **M9**, uncaught before: `[gate-job-work-step-is-unconditional]`.
# `if: github.event_name == 'schedule'` on the STEP (not the job): the job
# runs, the step that looks at a frame is skipped, the job is `success`, and
# the image publishes with no picture ever taken
@test "gates: an if: on the Tier B acceptance STEP is caught" {
  _mutate "/^      - name: Tier B visual acceptance/a\\        if: github.event_name == 'schedule'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# M54: the same shape on verify-tag-shape's only working step. The shape check
# never runs, the job succeeds, and a tag the image-tag deriver cannot publish
# reaches call-release -- the exact ordering failure that job exists to stop.
# why: **M54**, uncaught before: same id. The shape check never runs, the
# job succeeds, and a malformed tag reaches the Release
@test "gates: if: false on verify-tag-shape's only step is caught" {
  _mutate "s#^        if: \${{ github.ref_type == 'tag' }}\$#        if: false#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# The other half of that property: deleting the work step entirely must not be
# a pass either. A gate job with nothing in it is a gate in name only.
# why: The other half of that property: a gate job with no work left in it
# is a gate in name only. A `--print-<something>` query does not keep the
# count non-zero
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
# why: `[no-job-needs-a-report-only-job]` -- `release-blocked-report` /
# `nightly-tier-b-report` use `always()` and exist only to ADD a failure; a
# job that waits on one inherits that `always()`
@test "gates: making a report-only job a dependency is caught" {
  _mutate 's/needs: \[call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence\]/needs: [call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence, release-blocked-report]/'
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
# why: **M16**, uncaught before:
# `[publish-image-status-function-is-narrow]`. Property 4 checked
# `call-release` only. `always()` also runs the job in a CANCELLED run, and
# a cancelled Tier B (evicted from the GPU concurrency group as a pending
# member) is a documented case here. The id was
# `[publish-image-carries-no-always]` until M5 below: naming the property
# after one literal is what let a second literal through
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
# why: **M33**, uncaught before: `[call-release-needs-tier-b]` +
# `[no-job-needs-a-status-gated-job]`. An `always()`-gated
# `tier-b-visual-e2e-summary` satisfied a SUBSTRING search of `needs:`, so a
# Release was cut for a commit whose Tier B failed. `needs:` is now a list
# matched by membership, and nothing may need a job whose own condition
# carries a status function
@test "gates: a decoy job named after the gate does not satisfy a needs" {
  {
    sed 's/needs: \[verify-tag-shape, verify-tag-on-main, call-docker-build, tier-b-visual-e2e, require-picture-evidence\]/needs: [verify-tag-shape, verify-tag-on-main, call-docker-build, tier-b-visual-e2e-summary, require-picture-evidence]/' \
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
  run grep -qF 'tier-b-visual-e2e-summary,' "${MUTATED}"
  assert_success
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-needs-tier-b]"
  assert_output --partial "[no-job-needs-a-status-gated-job]"
}

# Reading `needs:` as a list rather than a string is only an improvement if it
# still reads the OTHER valid spellings of the same list.
# why: Reading `needs:` as a list is only an improvement if it still reads
# the other valid spellings of the same list: `["a", "b"]` is `[a, b]`, and
# a membership test that keeps the quotes reports a correct workflow as
# missing its gate
@test "gates: a quoted needs list is read as the same list" {
  _mutate 's/needs: \[verify-tag-shape, verify-tag-on-main, call-docker-build, tier-b-visual-e2e, require-picture-evidence\]/needs: ["verify-tag-shape", "verify-tag-on-main", "call-docker-build", "tier-b-visual-e2e", "require-picture-evidence"]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# A `needs:` naming a job that is not in the file is a workflow GitHub refuses
# to run; this checker must not read the dangling name's absent condition as
# "no status function" and report the invariant as held.
# why: `[needs-name-a-job-that-exists]` -- GitHub refuses such a workflow,
# and the checker would otherwise read the dangling name's absent `if:` as
# "no status function"
@test "gates: a needs naming a job that does not exist is caught" {
  _mutate 's/needs: \[verify-tag-shape, verify-tag-on-main\]$/needs: [verify-tag-shape-v2, verify-tag-on-main]/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[needs-name-a-job-that-exists]"
}

# M2. A name list cannot see a new entry: this job logs in to GHCR and pushes
# an image, needs only the build, and is behind no gate whatsoever. The set of
# jobs that can publish is DERIVED from the file.
# why: **M2**, uncaught before:
# `[publishing-job-is-behind-the-picture-gate]`. A `publish-image-hotfix:`
# job that logs in to GHCR and pushes, `needs: [call-docker-build]` only,
# was invisible to a name list. The publishing set is now derived from the
# file
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
# why: `[publishing-jobs-are-identifiable]` -- a gate that can no longer
# find the thing it gates is reporting on nothing
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
# why: **M50**, uncaught before: `[report-only-jobs-still-exist]`. Nothing
# depends on them by design, so deleting both broke no other check and
# silently restored the silence they were added to end
@test "gates: deleting the report-only jobs is caught" {
  _mutate '/^  release-blocked-report:$/,$d'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[report-only-jobs-still-exist]"
}

# Half a deletion is the same loss: a report that can no longer observe a need
# which did not succeed reports nothing.
# why: Same id: narrowing `!= 'success'` to one result is the same loss as
# deleting the job
@test "gates: a report-only job that can no longer observe the gate is caught" {
  _mutate "s/^      && needs.tier-b-visual-e2e.result != 'success'\$/      \&\& needs.tier-b-visual-e2e.result == 'failure'/"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[report-only-jobs-still-exist]"
}

# M52. The gate's whole job is to boot a real Kit producer and assert a real
# browser renders a non-black frame from it, and no hosted runner has NVENC --
# so moving it to ubuntu-latest does not make the gate slower, it removes it.
# why: **M52**, uncaught before: `[tier-b-runs-on-the-gpu-runner]`. No
# hosted runner has NVENC, so `runs-on: ubuntu-latest` does not slow the
# gate down, it removes it
@test "gates: moving the picture gate off the GPU runner is caught" {
  _mutate 's/^    runs-on: \[self-hosted, gpu\]$/    runs-on: ubuntu-latest/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# ------------------------------------------------------- tag reachability --

# why: `[workflow-triggers-on-tag-push]` -- a tag that does not start the
# workflow never reaches the gate
@test "gates: removing the tag push trigger is caught" {
  _mutate "/^      - 'v\[0-9\]/d"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[workflow-triggers-on-tag-push]"
}

# M20. Property 7 asked whether `on.push.tags` had any items in it, not
# whether a real version tag matches one. Both shapes this repo cuts are
# probed, because the incident behind the rule was an rc.
# why: **M20**, uncaught before: `[tag-globs-match-a-real-version]`.
# Presence was all that was checked, so `- 'never-matches-anything'` passed
# while `v1.2.3` started no workflow at all -- fails safe AND silently. Real
# tags are now tried against the patterns, translated from GitHub's filter
# syntax to an ERE
@test "gates: tag globs that match no real version are caught" {
  _mutate "s/^      - 'v\[0-9\].*\$/      - 'never-matches-anything'/"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-globs-match-a-real-version]"
}

# why: Same id, `v1.2.3-rc1`: the incident behind this rule was an rc, so a
# glob set that quietly stops matching pre-releases is the same hole
@test "gates: tag globs that stop matching pre-release tags are caught" {
  _mutate "/^      - 'v\[0-9\]+.\[0-9\]+.\[0-9\]+-\*'\$/d"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-globs-match-a-real-version]"
  assert_output --partial "v1.2.3-rc1"
}

# why: `[tier-b-reachable-on-every-tag-push]` -- the gate must run for every
# tag push, not some
@test "gates: tier-b losing its bare tag-push alternative is caught" {
  _mutate "s#^      || startsWith(github.ref, 'refs/tags/')\$#      || startsWith(github.ref, 'refs/heads/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-reachable-on-every-tag-push]"
}

# The subtler half: the tag alternative is still THERE, but ANDed instead of
# ORed, so the condition is false for an ordinary tag push.
# why: Same id, subtler mutation: the alternative is still there but ANDed,
# so the condition is false for an ordinary tag push. A substring grep
# passes this; splitting the expression at parenthesis depth 0 does not
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
# why: **M22**, a FALSE POSITIVE before: rejected as a violation even though
# `verify-tag-shape` ten lines away in the same file guards its own step
# with exactly that spelling. Tag-ref tests are matched against a set of
# spellings, and the error message names the set
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
# why: `[verify-tag-shape-has-no-job-level-if]` -- the gate needs it, and a
# SKIPPED need skips its dependent, so it carries no job-level `if:` by
# design (the tag check is guarded per-step)
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
# why: **C3**, uncaught in round 5: `[gate-job-work-step-is-unconditional]`.
# The gate's work step runs `true` and the helper it should run survives in
# a TRAILING COMMENT, which was all the "is there still work here" check
# read. The job ran, did nothing, reported success, and the image published
# with no picture taken
@test "gates: the Tier B work step neutered by a trailing comment is caught" {
  _mutate 's|^        run: bash script/ci/tier_b_visual_e2e.sh$|        run: "true"  # bash script/ci/tier_b_visual_e2e.sh|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# The GPU pin defeated the same way: `self-hosted` and `gpu` are both
# still in the line, in the comment, and the gate ran on a hosted runner with
# no NVENC -- which does not slow the picture check down, it removes it.
# why: **C4**: `[tier-b-runs-on-the-gpu-runner]`, defeated the same way --
# `runs-on: ubuntu-latest # was [self-hosted, gpu]`. Both words the check
# looked for are still on the line, in the comment
@test "gates: the GPU pin defeated by a trailing comment is caught" {
  _mutate 's|^    runs-on: \[self-hosted, gpu\]$|    runs-on: ubuntu-latest  # was [self-hosted, gpu]|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# Both report-only jobs neutered: their condition is now `false`, and the
# `!= 'success'` the shape check looked for survives in the comment. A blocked
# release goes back to being a grey job on a green-looking run.
# why: **C5**: `[report-only-jobs-still-exist]`. Both report conditions
# become `&& false` with the `!= 'success'` the shape check wanted surviving
# in the comment, so a blocked release goes back to a grey job on a
# green-looking run
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
# why: **T1**: `[publishing-step-is-unconditional]`, a new id. `steps:` with
# a trailing comment is not `steps:` to a line regex, so nothing below it
# was parsed and every step-level `if:` in `publish-image` became invisible
# -- here on the step that actually pushes. The job reports success having
# published nothing, and a tag cuts a Release with no image behind it
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
# why: **J1**: `[publishing-job-is-behind-the-picture-gate]`. A job header
# with a trailing comment is not a job header to a line regex, so the job
# was invisible to the job list, never derived as publishing and never
# required to carry the gate, while its body was silently attributed to the
# job above it
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

# why: **U2**: same id, the single-quoted `'if':` spelling
@test "gates: a single-quoted 'if': on the Tier B work step is caught" {
  _mutate "/^      - name: Tier B visual acceptance/a\\        'if': false"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-work-step-is-unconditional]"
}

# why: **D1**: same id, the spaced `if :` spelling
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

# why: **B2**: same id, the single-quoted spelling at job level
@test "gates: a single-quoted 'if': hiding a status function on call-release is caught" {
  _mutate "/^  call-release:\$/,/^  publish-image:\$/{s|^    if: >-\$|    'if': >-|}" \
          "s#^      startsWith(github.ref, 'refs/tags/')\$#      always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# why: **E1**: same id, the spaced spelling at job level
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

# why: **E3**: same id, the spaced spelling
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
# why: **G1**: `[publish-image-gate-is-not-optional]`. The round-5 tokeniser
# counted every `(` in the text, quoted strings included, so an unbalanced
# `(` inside a string literal pinned depth above zero, the `||` appended
# after it was invisible, and the whole gate chain became one alternative of
# a disjunction
@test "gates: a '(' inside a string hiding a top-level || is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      \&\& !contains(github.ref_name, '(')\n      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# The same in the other direction: a `)` inside a string drives depth
# BELOW zero, with the same effect and from the opposite side.
# why: **F1**: same id, from the opposite side -- a `)` inside a string
# drives depth BELOW zero for the same effect
@test "gates: a ')' inside a string hiding a top-level || is caught" {
  _mutate "/^              && inputs.publish_image_tag != ''))\$/a\\      \&\& !contains(github.ref_name, ')')\n      || inputs.publish_image_tag != ''"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-gate-is-not-optional]"
}

# ... and the acceptance half, so the fix is a tokeniser and not a ban on
# parentheses in strings: a condition that legitimately mentions one still
# passes.
# why: The acceptance half, so the fix is a string-literal-aware tokeniser
# and not a ban on parentheses in strings: a condition that legitimately
# mentions one still passes
@test "gates: a parenthesis inside a string literal is not a bypass by itself" {
  _mutate "s#^      && needs.tier-b-visual-e2e.result == 'success'\$#      \&\& needs.tier-b-visual-e2e.result == 'success'\n      \&\& !contains(github.ref_name, '(')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# A condition whose parentheses do not balance outside its strings cannot be
# split into terms at all. Guessing at one and reporting the invariant as held
# is the failure mode; refusing is not.
# why: `[condition-is-a-well-formed-expression]` -- a new id. A condition
# whose parentheses do not balance outside its strings cannot be split into
# terms at all; guessing at one and reporting the invariant as held is the
# failure mode, refusing is not
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
# why: **F2**: `[publishing-job-is-behind-the-picture-gate]`. A publishing
# command split across a folded scalar never appears contiguously in the raw
# text, so a substring search over the job body could not find it and the
# job was never derived as publishing. The parser folds the scalar before
# anything looks at it
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
# why: **N4**: same id. The publishing set was called DERIVED but was a
# search for nine literal strings, and `permissions: write-all` is one token
# that grants every scope there is
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
# why: **N5**: same id. A workflow-level `permissions:` block is the grant
# every job WITHOUT its own block runs with, so reading only job-level
# blocks made a workflow that handed write to everything look read-only
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
# why: **H1**: same id. `docker buildx build --push` names neither `docker
# push` nor `push: true`, the two docker spellings on the list
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
# why: **H2**: same id. A `push:` whose value is an expression could be true
# on any run; the list held the literal `push: true`
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
# why: The acceptance half of that widening: `push: false` is a build that
# does not push, and reporting it as a publishing job would teach a
# maintainer that the derivation is noise
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
# why: **M5**: `[publish-image-status-function-is-narrow]`. `!failure()` is
# true in a cancelled run, exactly like `always()`, and round 5 tested for
# the literal `always(` -- so the same escape walked through under another
# name. That is why the id names the PROPERTY the condition must have rather
# than one banned literal
@test "gates: !failure() in place of publish-image's !cancelled() is caught" {
  _mutate 's/^      !cancelled()$/      !failure()/'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[publish-image-status-function-is-narrow]"
}

# ... and the acceptance half: the two other spellings of the SAME narrow test
# must not be reported as violations, or the property becomes a ban on one
# literal all over again.
# why: The acceptance half: another spelling of the SAME narrow test must
# not be reported as a violation, or the property becomes a ban on one
# literal all over again
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
# why: **I1**, a legal edit round 5 reported as a violation:
# `continue-on-error: false` is the DEFAULT written out loud, and the check
# was a substring search for the word
@test "gates: continue-on-error: false is not a violation" {
  _mutate '/^  tier-b-visual-e2e:$/a\    continue-on-error: false'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# A trailing comment after a needs list was split on whitespace along with
# the list, and the words in it were reported as jobs that do not exist ("#",
# "the", "picture", "gate").
# why: **I2**, legal edit: a trailing comment after a `needs:` list was
# split on whitespace along with the list, and the words in it were reported
# as jobs that do not exist -- "#", "the", "picture", "gate"
@test "gates: a trailing comment after needs: is not four missing jobs" {
  _mutate 's|^    needs: \[call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence\]$|    needs: [call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence]  # the picture gate|'
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# `'on':` is the YAML-1.1-safe spelling of the trigger key -- YAML 1.1
# resolves a bare `on` to the boolean true, which is why the quoted form
# exists. Reading only the bare spelling reported a workflow with no triggers
# at all.
# why: **P3**, legal edit: `'on':` is the YAML-1.1-safe spelling of the
# trigger key -- YAML 1.1 resolves a bare `on` to the boolean true, which is
# why the quoted form exists -- and reading only the bare spelling reported
# a workflow with no triggers at all
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
# why: **P4**, legal edit: expressions were compared as strings against
# literal spellings, so the optional whitespace was load-bearing.
# `result=='success'` and `startsWith(github.ref,'refs/tags/')` are the
# expressions the workflow already contains, written without spaces GitHub
# does not require
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
# why: `[publish-image-requires-tier-b-success]` -- the pairing that stops
# P4's whitespace-insensitivity widening into "any expression containing the
# right words": the same spelling with the operand changed is still caught
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
# why: `[call-release-carries-no-status-function]` +
# `[gate-job-runs-its-driver-verbatim]`. GitHub expression function names
# are case-INSENSITIVE and the match was not, so `if: ALWAYS() &&
# startsWith(...)` was invisible to the property whose whole job is to keep
# a status function off `call-release` -- and that ABSENCE is what keeps
# GitHub's default skip propagation, which is what makes an unavailable GPU
# runner block the release. Paired with a work step suffixed `|| true`, it
# is the entire invariant
@test "gates: ALWAYS() on call-release is a status function like any other" {
  _mutate "s#^      startsWith(github.ref, 'refs/tags/')\$#      ALWAYS() \&\& startsWith(github.ref, 'refs/tags/')#" \
          "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# why: Same id, the mixed-case spelling: the fix is a case-insensitive
# match, not a second literal
@test "gates: Always() in mixed case is a status function like any other" {
  _mutate "s#^      startsWith(github.ref, 'refs/tags/')\$#      Always() \&\& startsWith(github.ref, 'refs/tags/')#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[call-release-carries-no-status-function]"
}

# The same root cause pointed the other way, at publish-image, where the
# property is "the ONLY status function here is the narrow !cancelled()".
# why: `[publish-image-status-function-is-narrow]` -- the same root cause
# pointed at the job where the property is "the only status function here is
# the narrow `!cancelled()`"
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
# why: The acceptance half, and the reason case-sensitivity was worth fixing
# rather than working around: it failed OPEN for the spelling an attacker
# wants and CLOSED for one a maintainer might write. `STARTSWITH(GitHub.ref,
# ...)` is the tag-ref test the workflow already has
@test "gates: STARTSWITH in capitals is still the tag-ref test" {
  _mutate "s@startsWith(github.ref, 'refs/tags/')@STARTSWITH(GitHub.ref, 'refs/tags/')@g"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# why: Same acceptance, on the narrow status test
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

# why: `[gate-job-runs-its-driver-verbatim]` -- a new id. The old property
# COUNTED steps naming something under `script/ci/`, so the driver with `||
# true` after it still counted. The gate ran, swallowed its own failure,
# reported success, and the image published with no picture taken
@test "gates: the Tier B driver suffixed with || true is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# why: Same id: `--help` exits 0 at once, and the count could not tell it
# from the job's work
@test "gates: the Tier B driver reduced to --help is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh --help@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# why: Same id, the `--version` spelling
@test "gates: the Tier B driver reduced to --version is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: bash script/ci/tier_b_visual_e2e.sh --version@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# why: Same id: `set +e; ...; exit 0` keeps the driver on the line and
# throws its result away
@test "gates: the Tier B driver wrapped in set +e and exit 0 is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: set +e; bash script/ci/tier_b_visual_e2e.sh; exit 0@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# The count could not tell one script/ci/ helper from another, so pointing the
# picture gate's work step at the tag deriver satisfied it exactly.
# why: Same id: the count could not tell `tier_b_visual_e2e.sh` from
# `derive_image_tag.sh`, so pointing the picture gate's work step at the tag
# deriver satisfied it exactly
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
# why: Same id: an UNCONDITIONAL `echo` naming `script/ci/` keeps the old
# count satisfied while `run: $CMD`, with the command in `env:`, sits behind
# an `if:` that is never true
@test "gates: an echo decoy plus the real work behind env indirection is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: echo 'the driver lives under script/ci/'\n        env:\n          CMD: bash script/ci/tier_b_visual_e2e.sh\n      - name: The real work, behind a condition\n        if: \${{ github.event_name == 'never' }}\n        run: eval \"\$CMD\"@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# why: Same id, with the real work as a third-party action
@test "gates: an echo decoy plus a guarded third-party action is caught" {
  _mutate "s#^        run: bash script/ci/tier_b_visual_e2e.sh\$#        run: echo 'see script/ci/ for what this used to do'\n      - name: The real work, behind a condition\n        if: \${{ github.event_name == 'never' }}\n        uses: some/visual-acceptance-action@v1#"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# why: Same id, with the real work as a plain inline `run:`
@test "gates: an echo decoy plus a guarded inline run is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        run: echo 'see script/ci/ for what this used to do'\n      - name: The real work, behind a condition\n        if: \${{ github.event_name == 'never' }}\n        run: ./take-the-picture.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# The same pin on the OTHER driver job. verify-tag-shape runs the deriver
# before anything irreversible happens; `|| true` there lets a tag the
# deriver cannot publish reach the GPU gate and the Release.
# why: Same id on the OTHER driver job: `verify-tag-shape` runs the deriver
# before anything irreversible, and `|| true` there lets a tag the deriver
# cannot publish reach the GPU gate and the Release
@test "gates: the tag deriver suffixed with || true is caught" {
  _mutate "s@^        run: bash script/ci/derive_image_tag.sh\$@        run: bash script/ci/derive_image_tag.sh || true@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# A `--print-<x>` QUERY is the one other spelling the job may contain -- this
# repo pulls the producer image the driver names -- and it must be
# unconditional too: a skipped query fails the step that consumes it.
# why: Same id. A `--print-<x>` query is the one other spelling the job may
# contain -- this repo pulls the producer image the driver names -- and it
# must be unconditional too, because a skipped query fails the step that
# consumes it
@test "gates: an if: on the driver's --print- query is caught" {
  _mutate "s|^        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"\$|        if: \${{ github.event_name == 'never' }}\n        run: docker pull \"\$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# ... and the acceptance half, so "exact" does not mean "byte-identical".
# Whitespace inside the command is not meaning; an ARGUMENT is, which is why
# every case above is a violation and this one is not.
# why: The acceptance half, so "exact" does not mean "byte-identical":
# whitespace inside the command is not meaning, an ARGUMENT is. Adding one
# is a violation whose message says to record the new spelling in
# `GATE_WORK_DRIVERS`
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
# why: `[gate-driver-runs-unmodified]` -- GitHub's documented custom-shell
# form is `command [...options] {0}`, so the pinned driver is PRINTED and
# never runs while the step and the job report success. The pin compared a
# STRING; four sibling keys decide what that string does
@test "gates: shell: cat {0} on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        shell: cat {0}\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The same hole spelled as something that reads like a lint tweak in review.
# why: Same id: syntax-check only, and it reads as a lint tweak in review
@test "gates: shell: bash -n {0} on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        shell: bash -n {0}\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The verbatim string, resolved against another tree -- a fixture holding a
# stub of the same path.
# why: Same id: the verbatim string resolved against another tree -- a
# fixture holding a stub of the same path
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
# why: Same id: the driver reads `TIER_B_PRODUCER_IMAGE` /
# `TIER_B_VIEWER_IMAGE` / `TIER_B_BOOT_TIMEOUT` from its environment, so the
# "picture" becomes one of whatever image the editor chose, with the pinned
# line intact
@test "gates: env: on the Tier B work step is caught" {
  _mutate "s@^        run: bash script/ci/tier_b_visual_e2e.sh\$@        env:\n          TIER_B_PRODUCER_IMAGE: ghcr.io/somewhere/else:latest\n        run: bash script/ci/tier_b_visual_e2e.sh@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# ... and the same variable one level up, which no step-level rule can see.
# why: Same id, one level up, where no step-level rule can see it
@test "gates: a job-level env: on the picture gate is caught" {
  _mutate "s@^    runs-on: \[self-hosted, gpu\]\$@    runs-on: [self-hosted, gpu]\n    env:\n      TIER_B_PRODUCER_IMAGE: ghcr.io/somewhere/else:latest@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# ... and two levels up, where it reaches every job in the file including
# this one.
# why: Same id, two levels up, where it reaches every job in the file
# including this one
@test "gates: a workflow-level env: reaching the picture gate is caught" {
  _mutate "s@^jobs:\$@env:\n  TIER_B_PRODUCER_IMAGE: ghcr.io/somewhere/else:latest\njobs:@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# THE THREE THAT NEVER TOUCH THE PINNED LINE. A reviewer reading the diff
# sees a `defaults:` block and a `run:` line that still says exactly what it
# always said.
# why: Same id. THE PINNED LINE IS UNTOUCHED: the diff shows only a
# `defaults:` block
@test "gates: a job-level defaults.run.shell on the picture gate is caught" {
  _mutate "s@^    runs-on: \[self-hosted, gpu\]\$@    runs-on: [self-hosted, gpu]\n    defaults:\n      run:\n        shell: cat {0}@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# why: Same id, and it is one block at the top of the file
@test "gates: a workflow-level defaults.run.shell is caught" {
  _mutate "s@^jobs:\$@defaults:\n  run:\n    shell: cat {0}\njobs:@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# why: Same id: the driver resolved from another tree, again with no edit to
# the step
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
# why: `[gate-job-runs-its-driver-verbatim]` -- clause (c) was `"--print-"
# in run`, a SUBSTRING test, so any unconditional step containing that
# literal anywhere got a free pass to invoke the driver in any spelling. Now
# every occurrence of the script in the step must itself be a `--print-<x>`
# query
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

# An env: on a step of the gate job that does NOT invoke the driver cannot
# change what the driver does: it is a different process.
# why: Acceptance pair for the `env:` refusal: a step that does not invoke
# the driver is a different process and cannot change what the driver does
@test "gates: env: on a non-driver step of the gate job still passes" {
  _mutate "s@^        run: ./script/build.sh -t e2e-test\$@        env:\n          DOCKER_BUILDKIT: '1'\n        run: ./script/build.sh -t e2e-test@"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# `defaults:` on a job that runs no pinned driver is an ordinary edit. The
# refusal is scoped to the two GATE_WORK_DRIVERS jobs and to the workflow
# level, which reaches them.
# why: Acceptance pair for the `defaults:` refusal, which is scoped to the
# two `GATE_WORK_DRIVERS` jobs and to the workflow level that reaches them
# -- not to the file
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
# why: `[publishing-job-is-behind-the-picture-gate]`. Shell-comment
# stripping ends a line at a whitespace-preceded `#`, which is right for
# recognising gate WORK and exactly wrong for deriving PUBLISHING -- losing
# the signal means the job is never required to stand behind the gate at
# all. Publishing is now derived from the RAW `run:` body
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

# why: Same id, with `gh release create` as the swallowed command
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
# why: Same id: `docker image push` is the subcommand spelling the table did
# not hold
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
# why: `[publishing-job-is-behind-the-picture-gate]` -- `PUBLISH_RUN_RE`
# carried a row that matched NOTHING REAL: `regctl (push|copy)`, and regctl
# has neither subcommand. A row that looks like coverage and provides none
# is worse than an admitted gap, because the name in the table is what stops
# anyone checking
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

# why: Same id, the other real spelling
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
# why: Same id: a registry login in a job that publishes nothing is not a
# normal pattern -- the same reasoning that puts `docker/login-action` in
# `PUBLISH_USES`. Added with the row it tests, because a row nothing
# exercises is the failure the two cases above correct
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
# why: Acceptance pair: a registry READ is not a publish, so the corrected
# rows did not widen into `regctl <anything>`
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

# why: Same id
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

# why: Same id
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

# why: Same id: `gh api -X POST /repos/<r>/releases` cuts a Release with no
# `gh release` on the line at all
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

# why: Same id, and the one that defeated EVERY row at once rather than one
# of them: each pattern matches within a single line, so a trailing `\` hid
# all of them. Continuations are joined before matching
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
# why: Same id: `step_text()` read `run` and `uses` only, so a command
# written as an `env:` value and reached with `eval "$CMD"` was invisible.
# `env:` values are searched for publishing signals -- deliberately, and
# only for publishing
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
# why: Same id, with the command in the JOB's `env:` rather than the step's
# -- reported as the job's, because a command written twenty lines above the
# steps would otherwise send a maintainer to the wrong step
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
# why: The acceptance half, and the one that matters most here: this repo's
# own `publish-image` READS `/repos/<r>/releases/tags/v<version>` from
# behind an `if:`, to refuse a publish with no Release behind it. Deriving
# that GET as the publishing act would report the guard itself as a
# violation, so the REST pattern is scoped to an explicit write method
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
# why: `[tag-globs-match-a-real-version]` -- `glob_to_regex()` had no `!`
# case, so a NEGATIVE pattern compiled to a literal one and matched nothing.
# Appending `- '!v[0-9]+.[0-9]+.[0-9]+-*'` silently excluded every release
# candidate while the property whose own comment reads PRESENCE IS NOT
# REACHABILITY passed. The incident behind this whole file was an rc
@test "gates: a negative tag glob that excludes every rc is caught" {
  _mutate "s|^      - 'v\[0-9\]+.\[0-9\]+.\[0-9\]+-\*'\$|      - 'v[0-9]+.[0-9]+.[0-9]+-*'\n      - '!v[0-9]+.[0-9]+.[0-9]+-*'|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tag-globs-match-a-real-version]"
}

# ... and the acceptance half, so honouring `!` does not become "any `!` is a
# violation": a negation that excludes something this repo never cuts leaves
# both probe tags reachable.
# why: The acceptance half, so honouring `!` does not become "any `!` is a
# violation"
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
# why: `[tag-trigger-has-no-path-filter]` -- a new id. Whether GitHub
# applies a `paths:` filter to a TAG push is not settled from the workflow
# text, and under the reading that matters an unmatchable filter silences
# every tag push while the tag patterns still look right. Refused rather
# than guessed
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
# why: GitHub matches runner labels case-insensitively and this file did
# not, while matching expressions case-insensitively -- the exact
# inconsistency the expression change argued against one round earlier. It
# failed CLOSED, so noise rather than a hole; noise is still how a check
# gets switched off
@test "gates: runner labels in mixed case are the same runner" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: [Self-Hosted, GPU]|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# ... and its failing half, so case-insensitivity did not become "any label
# set will do": the GPU label still has to be there, in some case.
# why: `[tier-b-runs-on-the-gpu-runner]` -- the failing half, so
# case-insensitivity did not become "any label set will do"
@test "gates: a mixed-case label set that has lost the GPU is still caught" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: [Self-Hosted, Ubuntu-Latest]|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# why: `{group: gpu-hosts, labels: [self-hosted, gpu]}` is documented GitHub
# syntax and `as_list()` on a mapping yielded `str(dict)`, so it was
# reported as a gate that had left the GPU -- a false positive that would
# fire the day the org moves the GPU host into a runner group
@test "gates: a runner group that still declares the labels passes" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: {group: gpu-hosts, labels: [self-hosted, gpu]}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# why: Same false positive for `runs-on: ${{ matrix.runner }}`, now resolved
# against the job's own `strategy.matrix`
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
# why: `[tier-b-runs-on-the-gpu-runner]` -- the failing half. Which machines
# are in a group is a repo SETTING, which the checker cannot read, so a
# group with no labels comes back as unresolved rather than as a silent pass
@test "gates: a runner group with no labels is not proof of a GPU runner" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    runs-on: {group: gpu-hosts}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# why: Same id: EVERY value the matrix could take must satisfy the
# requirement, or the gate runs off the GPU for half its variants
@test "gates: a matrix with one hosted runner is caught" {
  _mutate "s|^    runs-on: \[self-hosted, gpu\]\$|    strategy:\n      matrix:\n        runner: [[self-hosted, gpu], [ubuntu-latest]]\n    runs-on: \${{ matrix.runner }}|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[tier-b-runs-on-the-gpu-runner]"
}

# why: Same id: an expression whose value is decided by an input or a caller
# is not determined here, and is reported rather than guessed
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
# why: The awk implementation this replaced could die with status 141 and NO
# OUTPUT AT ALL -- a SIGPIPE between two of its own helpers, deterministic
# on the J1 input above. A checker that says nothing and exits non-zero
# teaches a maintainer to re-run it until it is quiet, which is a gate with
# a retry button. Every exit says something, and only 0, 1 and 2 are defined
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

# ==========================================================================
# THE EVIDENCE CHAIN
# ==========================================================================
#
# Every property above this point asks a question about the TEXT of
# main.yaml. Review round 8 proved that class of question has a floor: five
# single-step edits -- `: > script/ci/tier_b_visual_e2e.sh --print-x`,
# `sed -i '1a exit 0' script/ci/*.sh`, a $GITHUB_PATH entry shadowing `bash`,
# a job-level `container:` whose bash is a stub, and $GITHUB_ENV aiming
# TIER_B_PRODUCER_IMAGE at busybox -- each leave a workflow this checker
# passes and a job that goes green having sampled no frame at all. They are
# not spellings to enumerate; they are five members of an unbounded family,
# and the checker's own PUBLISH_RUN_RE comment already concedes enumerations
# do not converge.
#
# The answer is not a sixth spelling. It is to stop taking the job's word for
# it: the acceptance spec writes an attestation only after sampling a frame
# that cleared every threshold, and publish-image refuses to push without it.
# All five bypasses fail that check at once, because all five end the same way
# -- no frame, no attestation.
#
# That only holds while the chain is intact, so the chain is what these cases
# lock. Cutting any link is exactly the edit an attacker (or a tired
# maintainer) would make next.

@test "gates: tier-b publishes its attestation as a job output" {
  _mutate '/^    outputs:$/,/^      attestation:/d'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: the acceptance step keeps the id its output is read from" {
  _mutate 's|^        id: acceptance$|        id: something-else|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: deleting the evidence gate job is caught" {
  _mutate '/^  require-picture-evidence:$/,/^  publish-image:$/{/^  publish-image:$/!d}'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

# The guard used to be inline shell and this case weakened its `if`. It is a
# pinned invocation now -- precisely because round 10 defeated the inline form
# four ways -- so the equivalent attack is to point the pin somewhere else.
@test "gates: an evidence gate pointed at another script is caught" {
  _mutate 's|^        run: bash script/ci/require_attestation.sh$|        run: bash script/ci/derive_image_tag.sh|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: an evidence gate reading nothing is caught" {
  _mutate 's|^      ATTESTATION: \${{ needs.tier-b-visual-e2e.outputs.attestation }}$|      ATTESTATION: "ok"|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: an evidence gate with a status function is caught" {
  _mutate 's|^  require-picture-evidence:$|  require-picture-evidence:\n    if: always()|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: a publisher dropping the evidence gate from needs is caught" {
  _mutate 's|^    needs: \[call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence\]$|    needs: [call-docker-build, call-release, tier-b-visual-e2e]|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: a publisher that stops requiring the evidence gate is caught" {
  _mutate "/^      && needs.require-picture-evidence.result == 'success'\$/d"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

# ==========================================================================
# THE FIVE ROUND-8 BYPASSES
# ==========================================================================
#
# Each of these was GREEN against the round-8 checker and publishes a version
# nobody saw a frame from. They are locked here as the regression suite for
# the shape of the mistake, not just the five instances: every one of them
# reaches the driver WITHOUT naming it verbatim, which is precisely what the
# old exact-path substring test could not see.
#
# The evidence chain above is what actually stops them at publish time. These
# cases exist so the checker reports them too -- a gate that fails late and
# silently teaches nobody, and the operator who wrote the edit deserves to be
# told at the point they wrote it.

_gate_step() {
  _mutate "s|^        run: bash script/ci/tier_b_visual_e2e.sh\$|        run: bash script/ci/tier_b_visual_e2e.sh\n      - name: prep\n        run: ${1}|"
}

@test "gates: truncating the driver with a --print- token appended is caught" {
  _gate_step "': > script/ci/tier_b_visual_e2e.sh --print-x'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: overwriting the driver with a --print- token appended is caught" {
  _gate_step "'echo true > script/ci/tier_b_visual_e2e.sh --print-producer-image'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: rewriting the driver through a glob is caught" {
  _gate_step "'sed -i \"1a exit 0\" script/ci/*.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: a redundant path separator does not hide a rewrite" {
  _gate_step "'sed -i \"1a exit 0\" script/ci//tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: rewriting a sibling script in script/ci is caught" {
  _gate_step "'sed -i \"1a exit 0\" script/ci/derive_image_tag.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: a step writing the producer image to \$GITHUB_ENV is caught" {
  _gate_step "'echo \"TIER_B_PRODUCER_IMAGE=busybox:latest\" >> \"\$GITHUB_ENV\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: a step shadowing bash through \$GITHUB_PATH is caught" {
  _gate_step "'echo /tmp/shim >> \"\$GITHUB_PATH\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: a container: on the gate job is caught" {
  _mutate 's|^    runs-on: \[self-hosted, gpu\]$|    container:\n      image: ubuntu:24.04\n    runs-on: [self-hosted, gpu]|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: services: on the gate job is caught" {
  _mutate 's|^    runs-on: \[self-hosted, gpu\]$|    services:\n      db:\n        image: postgres\n    runs-on: [self-hosted, gpu]|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The other half of the same fix: it must not cry wolf. Round 8 began
# rejecting a correct edit (a redirect on the --print- query) for the same
# reason it accepted the truncations -- it read the text after the path
# without reading the command before it.

# ==========================================================================
# ROUND-9 REVIEW FINDINGS
# ==========================================================================
#
# The evidence chain landed in round 9 and its reviewer took it apart the same
# day: three of its four links were locked by SUBSTRING tests, which is the
# failure this file has now written down three times while committing it a
# fourth. These cases are the structural versions.

@test "gates: a redundant separator before ci does not hide a rewrite" {
  _gate_step "'sed -i \"1a exit 0\" script//ci/tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: a dot component in the path does not hide a rewrite" {
  _gate_step "'sed -i \"1a exit 0\" script/./ci/tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: only the pinned work step may write \$GITHUB_OUTPUT" {
  _gate_step "'printf \"attestation=1920x1080\\\\n\" >> \"\$GITHUB_OUTPUT\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: continue-on-error on the evidence gate is caught" {
  _mutate 's|^  require-picture-evidence:$|  require-picture-evidence:\n    continue-on-error: true|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-has-no-continue-on-error]"
}

# Shadowing the binding at step level was one of round 10's four. The gate's
# work being pinned makes `env:` on that step a refused modifier outright --
# the same rule that protects the Tier B driver, inherited for free, which is
# the whole reason the guard became a pinned script.
@test "gates: a step-level env on the pinned evidence gate is caught" {
  _mutate 's|^      - name: Refuse a release whose picture left no evidence$|      - name: Refuse a release whose picture left no evidence\n        env:\n          ATTESTATION: sentinel|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: a constant standing in for the attestation output is caught" {
  _mutate 's|^      attestation: \${{ steps.acceptance.outputs.attestation }}$|      attestation: "acceptance-ok"|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: the acceptance step's outcome is not its evidence" {
  _mutate 's|^      attestation: \${{ steps.acceptance.outputs.attestation }}$|      attestation: ${{ steps.acceptance.outcome }}|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

# The other direction, and the reason _READ_ONLY_COMMANDS is a table rather
# than a guess: the round-9 directory sweep reported `shellcheck <driver>`,
# `ls script/ci/` and running this very checker as bypasses. A gate that cries
# wolf on correct edits gets edited out.


@test "gates: a read-only command with a redirect onto the driver is caught" {
  _gate_step "'cat /dev/null > script/ci/tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# ==========================================================================
# ROUND-10 REVIEW FINDINGS
# ==========================================================================
#
# The round-10 reviewer did not argue that the evidence chain COULD be
# bypassed. They installed a `docker` shim through `${GITHUB_PATH:?}`, ran the
# real driver, and got:
#
#   [tier-b] attestation verified: 1920x1080 meanLuma=151.99 ...
#   [tier-b] PASS: a real browser rendered a real, non-black frame ...
#
# with no GPU, no Kit, no browser and no frames -- while this checker printed
# "holds the release invariant". The invariant did not hold.
#
# Two lessons, both structural rather than another spelling:
#   - Enumerating shell EXPANSION syntax loses the same way enumerating path
#     spellings lost. Every form contains the variable's NAME; match that.
#   - Asking "does this shell text fail on empty?" is a question about a
#     Turing-complete language. The gate's work is pinned as an invocation
#     instead, which is the mechanism that already works for the driver.

_out_expr() { _mutate "s@^      attestation: \\\${{ steps.acceptance.outputs.attestation }}\$@      attestation: ${1}@"; }

@test "gates: an || fallback on the attestation output is caught" {
  _out_expr "\${{ steps.acceptance.outputs.attestation || 'ok' }}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: concatenating onto the attestation output is caught" {
  _out_expr "\${{ steps.acceptance.outputs.attestation }}\${{ github.sha }}"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: one extra character on the attestation binding is caught" {
  _mutate "s@^      ATTESTATION: \\\${{ needs.tier-b-visual-e2e.outputs.attestation }}\$@      ATTESTATION: \${{ needs.tier-b-visual-e2e.outputs.attestation }}.@"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

@test "gates: replacing the pinned evidence gate with inline shell is caught" {
  _mutate 's@^        run: bash script/ci/require_attestation.sh$@        run: |\n          if [ -z "${ATTESTATION}" ]; then echo warn; fi\n          if false; then exit 1; fi@'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

# Every one of these published an image with no frame, confirmed against the
# real driver. They are four spellings of one expansion; the check is on the
# NAME, so a fifth costs nothing.
@test "gates: GITHUB_PATH reached through a default-value expansion is caught" {
  _gate_step "'echo /tmp/shim >> \"\${GITHUB_PATH:?}\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: GITHUB_ENV reached through a fallback expansion is caught" {
  _gate_step "'echo X=1 >> \"\${GITHUB_ENV:-/dev/null}\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: GITHUB_OUTPUT reached through printenv is caught" {
  _gate_step "'echo a=b >> \"\$(printenv GITHUB_OUTPUT)\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: GITHUB_OUTPUT reached through indirect expansion is caught" {
  _gate_step "'v=GITHUB_OUTPUT; echo a=b >> \"\${!v}\"'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

@test "gates: an in-place rewriter is not a read-only mention" {
  _gate_step "'shfmt -w script/ci/tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-its-driver-verbatim]"
}

@test "gates: cd-ing into the driver's directory is caught" {
  _mutate 's@^        run: bash script/ci/tier_b_visual_e2e.sh$@        run: bash script/ci/tier_b_visual_e2e.sh\n      - name: prep\n        run: |\n          cd script/ci\n          sed -i "1a exit 0" tier_b_visual_e2e.sh@'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-driver-runs-unmodified]"
}

# The other direction. Round 10's regression was mine: the read-only table
# was recorded by match START while the pattern swallows any prefix the path
# carries, so `./script/ci/<driver>` was skipped in one pass and re-reported
# as a rewrite in the next. The cases written to prove the table worked used
# only the bare spelling -- the test proved the wrong thing, one level down.
# These use the spelling a human actually writes.


# ==========================================================================
# THE ALLOW-LIST
# ==========================================================================
#
# Round 11 ended the blocklist experiment. Its payload --
#
#   find . -name 'tier_b_visual_e2e.sh' -exec sed -i '2i exit 0' {} +
#
# -- names neither the directory every path test keys on nor any variable the
# name tests match, and it was EXECUTED against the real scripts: both drivers
# exited 0, the evidence gate printed "picture verified", the checker printed
# "holds the release invariant". Eleven rounds, eleven times a reviewer found
# the next spelling within the hour.
#
# So gate-job steps are now declared, and anything else is refused whatever it
# does. These cases prove the inversion holds where every enumeration failed:
# the first two are spellings nobody enumerated, and they are refused for the
# only reason that generalises -- nobody declared them.

@test "gates: reaching the driver by basename through find is caught" {
  _gate_step "'find . -name \"tier_b_visual_e2e.sh\" -exec sed -i \"2i exit 0\" {} +'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: reaching the driver through a directory glob is caught" {
  _gate_step "'sed -i \"2i exit 0\" script/*/tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: an undeclared action in a gate job is caught" {
  _mutate 's|^    steps:\n      # Pre-checkout self-heal|XXX|; s|^      # Pre-checkout self-heal: a prior GPU run can leave root-owned residue in$|      - uses: actions/setup-node@v4\n      # Pre-checkout self-heal: a prior GPU run can leave root-owned residue in|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: writing the runner's file-command file directly is caught" {
  _gate_step "'echo /tmp/shim >> \"\$RUNNER_TEMP\"/_runner_file_commands/add_path_x'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: pushd into the driver's directory is caught" {
  _gate_step "'pushd script/ci \&\& sed -i \"2i exit 0\" tier_b_visual_e2e.sh'"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: a decoy step wearing the acceptance id is caught" {
  _mutate 's|^        id: acceptance$|        id: real|; s|^      - name: Tier B visual acceptance (real producer -> real frames)$|      - name: decoy\n        id: acceptance\n        run: echo x\n\n      - name: Tier B visual acceptance (real producer -> real frames)|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

# The evidence gate runs a script, so it must be able to SEE that script. It
# shipped for one commit without a checkout: exit 127 on every run, and since
# both publishers require its success, no release could ever be cut again.
# Fails closed, which is the safe direction and no comfort -- it would have
# been found on the next tag push, by a person, at the worst moment.
@test "gates: every gate job that runs a repo script checks the repo out" {
  run bash "${CHECK}" "${WORKFLOW}"
  assert_success
  run grep -c 'uses: actions/checkout@' "${WORKFLOW}"
  assert_success
  # tier-b-visual-e2e, verify-tag-shape, verify-tag-on-main, publish-image, require-picture-evidence
  [ "${output}" -ge 5 ]
}

# The six cases that used to live near here asserted that a LEGITIMATE extra
# step in a gate job -- `shellcheck <driver>`, `cat ./<driver>`, a redirect on
# the --print- query -- was not a bypass. They were right under a blocklist,
# where the question was "does this step name something forbidden?", and they
# are obsolete under an allow-list, where no undeclared step in a gate job is
# permitted at all. Deleted rather than weakened: a case asserting a premise
# that no longer holds is worse than no case, because it passes for the wrong
# reason or fails for the right one and gets "fixed".
#
# What replaces them is the contract itself. Editing a declared step is a
# two-line change -- the workflow and the table -- and that is the cost the
# allow-list charges in exchange for converging.
@test "gates: editing a declared step without declaring it is caught" {
  _mutate 's|^        run: ./script/build.sh -t e2e-test$|        run: ./script/build.sh -t e2e-test --no-cache|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: the declared --print- query step is not read as a bypass" {
  # The shipped workflow contains a step that legitimately names the driver
  # (`docker pull "$(bash <driver> --print-producer-image)"`). It is declared,
  # and the mutation sweep must not report it -- this is the whole workflow
  # going green, asserted where a reader looking for that property finds it.
  run bash "${CHECK}" "${WORKFLOW}"
  assert_success
  run grep -c -- '--print-producer-image' "${WORKFLOW}"
  assert_success
  [ "${output}" -ge 1 ]
}

# ==========================================================================
# THE ALLOW-LIST, ATTACKED
# ==========================================================================
#
# An allow-list only converges if it is CLOSED. Its first version was not: a
# `" *"` suffix meant "starts with this", and
#
#   ./script/setup.sh apply && find . -name 'tier_b_visual_e2e.sh' \
#     -exec sed -i '2i exit 0' {} +
#
# matched a declared entry, because a prefix cannot tell an argument from a
# chained command. That is the blocklist's mistake wearing the allow-list's
# clothes -- a pattern open at one end is open to everything past it. There is
# no wildcard now; an entry is the whole step.

@test "gates: a declared prefix cannot carry a chained command" {
  _mutate 's|^        run: ./script/build.sh -t e2e-test$|        run: ./script/setup.sh apply \&\& find . -name "tier_b_visual_e2e.sh" -exec sed -i "2i exit 0" {} +|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: appending a command to a declared step is caught" {
  _mutate 's|^        run: ./script/build.sh -t e2e-test$|        run: ./script/build.sh -t e2e-test; sed -i "2i exit 0" script/ci/tier_b_visual_e2e.sh|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
}

@test "gates: changing a declared step's flags is caught" {
  _mutate 's|^        run: ./script/build.sh -t e2e-test$|        run: ./script/build.sh -t e2e-test --no-cache|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

# The @ref is part of the action. Matching the name alone would let a declared
# step be repointed at a moving tag or a fork -- the supply-chain half of the
# same hole.
@test "gates: repointing a declared action at a moving ref is caught" {
  _mutate 's|uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02|uses: actions/upload-artifact@main|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: repointing a declared action at a fork is caught" {
  _mutate 's|uses: actions/upload-artifact@|uses: evilfork/upload-artifact@|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

# The trust boundary is the MACHINE, not the job. The GPU runner is persistent
# and shared, so a job nobody declared can prepare the ground for the one that
# takes the picture -- edit the workspace, plant a shim on PATH -- while the
# gate job's own steps stay exactly as declared.
@test "gates: an undeclared job on the self-hosted runner is caught" {
  _append_job <<'JOB'
  helper:
    runs-on: [self-hosted, gpu]
    steps:
      - run: find . -name 'tier_b_visual_e2e.sh' -exec sed -i '2i exit 0' {} +
JOB
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

# ==========================================================================
# EVERY WORKFLOW, NOT JUST main.yaml
# ==========================================================================
#
# The checker read ONE file. A second workflow was not "allowed" -- it was
# UNANALYSED, which is worse, so a blunt assertion stood in for the analysis:
#
#   find /workflows -mindepth 1  ->  must equal exactly "main.yaml"
#
# That held until something legitimate arrived. base v0.43.0's `upgrade.sh`
# creates `.github/workflows/base-version-monitor.yaml` in the consumer, and
# a green build went red on upgrade with nothing wrong: that workflow is
# `schedule`/`workflow_dispatch`, `contents: read` + `issues: write`, and
# pushes nothing. The guard could not tell it from a publisher, because it was
# never looking at content -- only at how many files there were.
#
# Matching on filename would be worse than the blunt rule: an attacker names
# their file `base-version-monitor.yaml` and walks in. Hashing is a list to
# maintain and goes stale the moment base changes the file.
#
# So the question stops being "do I recognise this file?" and becomes "CAN IT
# PUBLISH?" -- which the checker already derives, from permissions, actions
# and commands, and which no filename can lie about. Every workflow in the
# directory is analysed; a workflow that cannot publish is fine however many
# there are; one that can must stand behind the picture gate like any other.

@test "gates: a non-publishing sibling workflow is accepted" {
  _sibling_workflow "monitor.yaml" \
    'name: Monitor
on:
  schedule:
    - cron: "0 3 * * *"
permissions:
  contents: read
  issues: write
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo checking'
  run bash "${CHECK}" "${WORKFLOW_DIR}"
  assert_success
  assert_output --partial "holds the release invariant"
}

@test "gates: a publishing sibling workflow outside the gate is caught" {
  _sibling_workflow "sneaky.yaml" \
    'name: Sneaky
on:
  push:
    tags: ["v*"]
permissions:
  packages: write
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - run: docker push ghcr.io/x/y:latest'
  run bash "${CHECK}" "${WORKFLOW_DIR}"
  assert_failure 1
  assert_output --partial "publishing-job-is-behind-the-picture-gate"
}

# The filename is not the credential. A publisher wearing the monitor's name
# is still a publisher.
@test "gates: a publisher named after the base monitor is still caught" {
  _sibling_workflow "base-version-monitor.yaml" \
    'name: Not really the monitor
on:
  push:
    tags: ["v*"]
permissions:
  packages: write
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - run: docker push ghcr.io/x/y:latest'
  run bash "${CHECK}" "${WORKFLOW_DIR}"
  assert_failure 1
  assert_output --partial "publishing-job-is-behind-the-picture-gate"
}

@test "gates: the checker reports which workflow the violation is in" {
  _sibling_workflow "sneaky.yaml" \
    'name: Sneaky
on:
  push:
    tags: ["v*"]
permissions:
  packages: write
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - run: docker push ghcr.io/x/y:latest'
  run bash "${CHECK}" "${WORKFLOW_DIR}"
  assert_failure 1
  assert_output --partial "sneaky.yaml"
}

@test "gates: a directory argument still checks main.yaml itself" {
  _sibling_workflow "monitor.yaml" \
    'name: Monitor
on:
  schedule:
    - cron: "0 3 * * *"
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok'
  # Break main.yaml inside the same directory: the sweep must not lose it.
  sed -i 's|^    needs: \[call-docker-build, call-release, tier-b-visual-e2e, require-picture-evidence\]$|    needs: [call-docker-build, call-release]|' \
    "${WORKFLOW_DIR}/main.yaml"
  run bash "${CHECK}" "${WORKFLOW_DIR}"
  assert_failure 1
}

# GitHub reads both extensions, so a sweep that only knows `.yaml` leaves the
# other half of the directory unexamined -- the exact blind spot this change
# exists to close, reintroduced one character narrower. Found by mutation:
# restricting the suffix tuple to `.yaml` alone broke nothing until this case.
@test "gates: a publishing sibling with a .yml extension is caught" {
  _sibling_workflow "release.yml" \
    'name: Ship
on:
  push:
    tags: ["v*"]
permissions:
  packages: write
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - run: docker push ghcr.io/x/y:latest'
  run bash "${CHECK}" "${WORKFLOW_DIR}"
  assert_failure 1
  assert_output --partial "release.yml"
}


# ==========================================================================
# THREE HOLES FOUND BY THE 2026-09-06 AUDIT
# ==========================================================================
#
# All three were executed against the shipped workflow before being written
# here: each mutation made the checker print "holds the release invariant"
# and exit 0, and each one is a way to publish a version whose picture was
# never verified. The mutations are kept verbatim as the cases below.

# HOLE 1. The evidence conjunct was checked by SUBSTRING while the tier-b
# conjunct next to it was checked STRUCTURALLY. `has_top_level_or` sees only
# a `||` at depth 0, so one pair of parentheses hid it: the substring is
# still present, no top-level `||` exists, and the picture evidence becomes
# one alternative of an OR. publish-image carries `!cancelled()`, so a FAILED
# evidence gate does not skip it -- the OR is the whole gate.
@test "gates: a publisher making the evidence gate one arm of an OR is caught" {
  _mutate "s|^      && needs.require-picture-evidence.result == 'success'\$|      \&\& (needs.require-picture-evidence.result == 'success' \|\| inputs.force_publish)|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

# The same shape one level in: a parenthesised alternative that MENTIONS the
# evidence job without requiring it.
@test "gates: a publisher requiring the evidence gate only on tags is caught" {
  _mutate "s|^      && needs.require-picture-evidence.result == 'success'\$|      \&\& (github.event_name != 'push' \|\| needs.require-picture-evidence.result == 'success')|"
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[picture-leaves-evidence]"
}

# HOLE 2. The undeclared-job-on-the-shared-runner check iterated
# `runs_on_variants()`, which returns a `(variants, problem)` TUPLE -- so it
# stringified the whole list and matched `self-hosted` case-SENSITIVELY,
# in a file that argues at length (canon_key) that GitHub matches labels
# case-insensitively. `[Self-Hosted, GPU]` reaches the same shared runner as
# `[self-hosted, gpu]` and was accepted.
@test "gates: an undeclared job on the self-hosted runner is caught in any case" {
  _append_job <<'YAML'

  audit-hole-2:
    runs-on: [Self-Hosted, GPU]
    steps:
      - run: find . -name tier_b_visual_e2e.sh -exec sed -i "2i exit 0" {} +
YAML
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: an undeclared job on a mixed-case self-hosted scalar is caught" {
  _append_job <<'YAML'

  audit-hole-2b:
    runs-on: Self-Hosted
    steps:
      - run: echo prepare the ground
YAML
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

# The other half of the same bug, and the one that decides what "correct"
# means here. A runner GROUP names machines listed in a repo SETTING this
# file cannot read, so it can neither confirm nor rule out the shared GPU
# box. The old code refused it -- but by ACCIDENT: it stringified the
# (variants, problem) tuple, and the remedy text for a group happens to
# contain the words `self-hosted` while the text for an undetermined matrix
# does not. Same input class, opposite verdicts, neither one chosen.
#
# It is chosen now, and it is refused: an undeclared job whose runner cannot
# be determined is treated as one that might land on the shared runner. On
# this workflow every job with no runs-on calls a reusable workflow and is
# out of scope by header item 5, so the cost of failing closed is a
# `labels:` line the day someone adds a group -- which the remedy text has
# been asking for all along.
@test "gates: an undeclared job on an undeterminable runner is caught" {
  _append_job <<'YAML'

  audit-hole-2c:
    runs-on:
      group: build-farm
    steps:
      - run: echo ordinary hosted work
YAML
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

# ...and the exemption that keeps that from being a false alarm on the
# shipped file: a job that CALLS a reusable workflow has no runs-on at all.
# call-docker-build and call-release are both this shape, so if the rule
# above did not skip them the workflow would fail its own checker.
@test "gates: an undeclared job that calls a reusable workflow is accepted" {
  _append_job <<'YAML'

  audit-hole-2d:
    uses: ./.github/workflows/main.yaml
YAML
  run bash "${CHECK}" "${MUTATED}"
  assert_success
  assert_output --partial "holds the release invariant"
}

# HOLE 3. `with:` was invisible to the step signature, which keyed on
# `uses:`+@ref or the collapsed `run:` only. So the pinned action stayed
# byte-identical while what it DID changed: `ref:` on the gate job's own
# checkout replaces the entire tree the driver is read from. The header's
# item 3(a) named this bypass and said the evidence chain covers it; it does
# not, because the swapped tree's driver can print a well-shaped attestation
# and require_attestation.sh only checks the shape.
@test "gates: repointing a declared checkout at another ref is caught" {
  _mutate 's|^        with:$|        with:\n          ref: refs/heads/not-the-tagged-commit|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}

@test "gates: dropping a declared checkout's with: is caught" {
  _mutate 's|^          submodules: recursive$|          submodules: false|'
  run bash "${CHECK}" "${MUTATED}"
  assert_failure 1
  assert_output --partial "[gate-job-runs-only-declared-steps]"
}
