#!/usr/bin/env python3
"""Assert the STRUCTURAL properties that make the release invariant true.

check_release_gates.py [<workflow.yaml>]

The rule is absolute and predates this file: no version may publish without
the Tier B picture gate having passed ON THAT COMMIT -- no override input, no
`continue-on-error`, no status-function escape, and an unavailable GPU runner
BLOCKS the release rather than being waved through (#70, after v0.3.0-rc1
published with no picture ever verified for it).

That rule lives in `if:` / `needs:` expressions in .github/workflows/main.yaml.
Every other gate this repo has -- bats, node, both e2e tiers, hadolint,
shellcheck -- stays green while the protection is deleted, because none of
them reads the workflow. This file is the thing that turns red for that.

WHY THIS IS A YAML PARSE AND NOT A GREP
---------------------------------------
Two earlier versions of this checker read the workflow as TEXT, with awk. A
reviewer walked 12 mutations past the first and 21 past the second. Almost
none of those were mistakes in an individual rule; they were properties of
reading YAML with line regexes:

  1. Comments. Stripping whole-line comments and then matching substrings
     over raw values means a trailing `#` satisfies or evades every one:
     `run: true  # script/ci/tier_b_visual_e2e.sh` left the gate doing
     nothing while still counting as the gate's work, and
     `runs-on: ubuntu-latest  # was [self-hosted, gpu]` defeated the GPU pin
     while the check for `self-hosted` still found the word.
  2. One spelling per construct. `if:`, `"if":`, `'if':` and `if :` are all
     valid YAML for the same key; a regex anchored on `^    if:` sees one of
     the four, and the other three are invisible at job AND step level.
  3. Parenthesis counting that is not string-literal aware. A `(` inside a
     quoted string pinned depth above 0 (and a `)` drove it below), which
     hid every subsequent top-level operator -- walking a top-level `||`
     straight past the check whose whole point was to be structural.
  4. A job header with a trailing comment is not a job. Its body was
     silently attributed to the job above it.

A real parser answers 1, 2 and 4 outright and reduces 3 to one tokeniser that
this file owns. So the workflow is parsed with PyYAML, which the `devel-test`
stage installs (`python3-yaml`) and no shipped image contains: `runtime` is
`FROM devel-base`, `devel-test` is `FROM devel`, and nothing is `FROM
devel-test`. Availability is checked by check_release_gates.sh, which refuses
with exit 2 rather than skipping.

Every violation is printed with a stable [id]. release_gate_workflow.bats
mutates the real workflow once per id and asserts THAT id is reported, so an
assertion here that cannot fail is itself caught -- the failure mode this
repo has been bitten by three times.

There is no silent exit. Every path out of main() prints something first, and
an unexpected exception is a traceback plus exit 2, never a bare status. The
awk implementation this replaced could exit 141 with no output at all, from a
SIGPIPE between two of its own helpers, on an input a reviewer supplied.

===========================================================================
WHAT THIS CANNOT SEE
===========================================================================
THIS LIST IS CANONICAL. doc/test/TEST.md, doc/changelog/CHANGELOG.md and the
four READMEs point AT it; they do not restate it, because four restatements
is how the list came to disagree with itself in four places while the most
productive attack in the last review (the comment channel) appeared in none
of them. An over-claimed gate is worse than a narrow one, because it stops
people looking.

 1. ONE FILE, BUT NO LONGER ONE FILE SILENTLY. A gate moved into a reusable
    workflow, a composite action, or a second workflow file is not examined;
    a `uses:` line naming one is read only for the publishing signals in
    PUBLISH_USES / PUBLISH_RUN_RE. That was the CHEAPEST bypass in the repo,
    because nothing enumerated `.github/workflows/`: a second workflow file
    with `on: push: tags: ['v*']` and a `docker push` published with no gate
    while every check here -- this one included -- stayed green. The
    `devel-test` stage now copies the DIRECTORY (`COPY .github/workflows/
    /workflows/`) and release_gate_workflow.bats asserts exactly which files
    are in it, so adding a workflow is a red test rather than a silence. The
    limitation itself is unchanged: THIS FILE still reads the one workflow it
    is given, and a second one is a decision for whoever adds it -- defend
    the invariant there too, or say why that file cannot publish. Reusable
    workflows and composite actions are not enumerated at all.
 2. GitHub's EXPRESSION SEMANTICS are not evaluated. Conditions are split at
    parenthesis depth 0 by this file's own tokeniser (string-literal aware,
    whitespace-insensitive, and now CASE-insensitive -- `if: ALWAYS()` walked
    the whole invariant past the case-sensitive version) and compared against
    closed sets of spellings (TAG_REF_TESTS, TIER_B_SUCCESS_TESTS,
    NOT_CANCELLED_TESTS). An equivalent expression written some OTHER way is
    reported as a violation -- a false positive whose fix is to add the
    spelling to that set -- and an inequivalent one that happens to
    canonicalise to a set member is not caught. `contains()`, `format()`,
    `fromJSON()` and every other function are opaque text.
 3. Gate WORK is pinned by IDENTITY for exactly the two jobs in
    GATE_WORK_DRIVERS (tier-b-visual-e2e, verify-tag-shape): each must carry
    a step whose `run:` is that job's driver invocation verbatim,
    unconditional, with no second guarded copy of the same script. For EVERY
    OTHER gate or publishing job the older, weaker test still applies -- "an
    unconditional step whose `run:`/`uses:` names something under
    `script/ci/`" -- and that one is a COUNT, not an identity: IN THOSE JOBS
    THE GATE'S WORK CAN STILL BE A NO-OP. An unconditional decoy naming the
    directory satisfies it while the real work sits behind an `if:`, whether
    that work is an inline `run:`, a third-party action, or a command reached
    through a variable. Shell comments are stripped from `run:` bodies for
    THIS purpose by a "whitespace-preceded `#` to end of line" heuristic, so
    a `#` inside a quoted shell string is treated as a comment here (it is
    NOT stripped when deriving publishing -- see 4).

    ON THE TWO PINNED JOBS the pin is now an INVOCATION rather than a string:
    `shell:`, `working-directory:` and `env:` are refused on a step that
    invokes the driver, and `defaults.run` and `env:` are refused on those
    jobs and at workflow level, because all three of `shell: cat {0}`,
    `working-directory:` and a `TIER_B_*` variable turn the pinned command
    into something that takes no picture WITHOUT editing the pinned line.
    That claim was WRONG AS WRITTEN for one round, and the correction is
    worth keeping visible: it used to say a step naming the driver "is
    examined whatever it does with it", and offered `run: echo exit 0 >
    script/ci/tier_b_visual_e2e.sh` as the example it catches. Round 8's
    reviewer appended one token -- `... > script/ci/tier_b_visual_e2e.sh
    --print-x` -- and the same step went green, because the argument reader
    took "text follows the path" to mean "the path was invoked" and handed
    the trailing token to the `--print-<x>` whitelist. The sentence claiming
    coverage was the specific thing that would have stopped the next reader
    looking there. Both are fixed: the classifier now reads the command
    BEFORE the path (driver_occurrences), and selection is on the driver's
    DIRECTORY, so a glob, a redundant separator and a sibling script are all
    examined.
    WHAT REMAINS OPEN IN THAT FAMILY, precisely:
      (a) A CHECKOUT OF ANOTHER REF can swap the driver out without any path
          under script/ci/ appearing in the step at all. `actions/checkout`
          with `ref:` is not read here. This is the one member of the family
          the directory sweep does not reach; the evidence chain (item 14)
          is what covers it, because a swapped driver still samples no frame.
      (b) `container:` and `services:` on the job ARE now refused outright,
          as are steps writing to `$GITHUB_ENV` or `$GITHUB_PATH`. They are
          named keys, not a general defence: a key GitHub adds tomorrow that
          reaches the driver the same way is covered by item 14, not here.
      (c) `defaults.run` is refused WHOLE rather than key by key, so a key
          GitHub adds later is covered by accident rather than by design.
          That is the intended direction, and it is why there is no list of
          `defaults.run` keys here to go stale.
      (d) what the driver ITSELF does is item 5.
 4. PUBLISHING is recognised by effective `permissions:` (job-level, else
    workflow-level), by the action names in PUBLISH_USES, by a truthy or
    expression-valued `push:` input, and by the command patterns in
    PUBLISH_RUN_RE, searched over the RAW `run:` body (comments not stripped,
    line continuations joined) plus step-level `env:` VALUES, with job-level
    `env:` read separately. Those
    three choices all trade a false positive for never missing a publish: a
    commented-out `docker push`, or one that only appears as the value of an
    env var, marks the job as one that must stand behind the gate.
    PUBLISH_RUN_RE IS AN ENUMERATION AND ENUMERATIONS DO NOT CONVERGE -- three
    rounds of widening have each been followed by a reviewer naming another
    spelling, and one row had been WRONG rather than merely incomplete
    (`regctl push|copy`, two subcommands regctl does not have, sitting in the
    table looking like coverage while `regctl image copy` went through), and a publishing command nobody has thought of yet is still not
    derived from its `run:`. What does not depend on the enumeration is the
    `permissions:` signal, which is a capability rather than a spelling. A
    job that publishes some other way -- an unfamiliar action, a helper
    script that pushes without saying so, a token passed to a program this
    list does not name -- is not derived from its commands and is caught only
    if it holds a write scope. One gap here is DELIBERATE and is a trade, not
    an oversight: `docker/build-push-action` is not a signal by itself, only
    its `push:` input is, because `push: false` is how this repo's own
    build-worker builds on every PR and listing the action reported every
    build job as one that must stand behind the release gate. The cost is
    that an invocation whose `push:` arrives from somewhere this file cannot
    resolve -- a reusable-workflow input, a changed upstream default -- is
    not derived.
 5. It says NOTHING about what the gate ASSERTS. That a picture was really
    looked at is tier_b_visual_e2e.sh's job and its own spec's; this file
    only guarantees that job ran, on the GPU, and that nothing published
    without it succeeding.
 6. REPO SETTINGS. Branch protection, required status checks, environment
    approval rules, and who may dispatch a workflow live in GitHub, not in
    this file. They are checked nowhere in this repo.
 7. WHAT THE RUNNER LABELS MEAN. `[self-hosted, gpu]` is asserted as a label
    set, matched case-INSENSITIVELY (GitHub matches labels that way; this
    file did not, and reported `[Self-Hosted, GPU]` as a gate that had left
    the GPU -- fail-closed noise, but the same inconsistency the expression
    change argued against). Whether the machine answering to `gpu` actually has an NVENC-capable
    GPU is not knowable from here. The four shapes of `runs-on` that CAN be
    resolved are a sequence, a scalar, a `{group:, labels:}` mapping and
    `${{ matrix.<name> }}` against this job's own `strategy.matrix`; a runner
    GROUP with no labels, and any other expression, are reported as
    unresolved rather than guessed -- which is a violation the day someone
    writes one legitimately, and the fix is to state the labels in the
    workflow.
 8. PyYAML IS NOT GITHUB'S PARSER. Anchors and aliases are expanded here and
    rejected by GitHub, so a workflow read through one would fail loudly at
    GitHub before it could publish -- the difference cannot hide a bypass,
    but the structure examined here is the expanded one, not the bytes. Any
    other construct where the two parsers disagree is a divergence that did
    not exist while both sides read text, and it is not enumerable from
    here. Duplicate keys, which GitHub rejects and PyYAML resolves
    last-wins, are refused outright for exactly this reason.
 9. IT NEEDS PyYAML. Outside the `devel-test` image the checker REFUSES
    (exit 2, by name) rather than running, so it is no longer true that this
    runs anywhere with bash. That is loud rather than silent, and the only
    caller is release_gate_workflow.bats inside the image that has the
    package -- but a future caller that ignores exit codes would have no
    check at all rather than a degraded one.
10. TRIGGER REACHABILITY is answered for TAG patterns only, and only against
    two probe tags (`v1.2.3`, `v1.2.3-rc1`). Negations (`!pattern`) are
    honoured, last match winning. A `paths:` / `paths-ignore:` filter on the
    same `push:` trigger is REFUSED rather than evaluated: whether GitHub
    applies a path filter to a tag push is not settled from the workflow
    text, and the reading that would matter (it does) makes an unmatchable
    path filter silence every tag push while the tag patterns still look
    right. Reachability through `workflow_call`, a `repository_dispatch`, or
    a workflow in another file is not considered at all.
11. GITHUB'S CASE RULES ARE ASSUMED, NOT DOCUMENTED. That expression function
    and context names are case-insensitive is what actions/languageservices
    implements and what the well-known write-ups say; GitHub's public
    expressions reference does not state it. This file therefore matches
    case-insensitively because that is safer under BOTH readings, not because
    the behaviour is documented -- see canon_key.

    THE ARGUMENT THAT ACTUALLY CARRIES THE DECISION, since "safer" was
    asserted rather than shown. Under a CASE-SENSITIVE GitHub, every spelling
    this file newly ACCEPTS fails closed or loud rather than publishing:
      - `ALWAYS()`, `!FAILURE()` and friends would be unknown functions, so
        the workflow errors at GitHub before any job runs. Loud.
      - `STARTSWITH(github.ref, ...)` in a job's `if:` is likewise an unknown
        function: the run fails rather than the job silently skipping.
      - `needs.x.result == 'SUCCESS'` would simply be false under a
        case-sensitive `==`, so the job it guards does not run. Closed.
    ONE ACCEPTANCE IS PERMISSIVE, and it is named here rather than left to be
    found: is_tag_ref_test is also the permitted exception on
    verify-tag-shape's driver step (property 10 and clause (b) of 10c). Under
    a case-sensitive reading `if: GITHUB.REF_TYPE == 'TAG'` is accepted THERE
    as the per-step tag guard while evaluating to something that never runs
    the step -- and verify-tag-shape has no job-level `if:` by design, so the
    job still reports 'success' and the picture gate downstream still starts.
    The consequence is bounded: the deriver's shape check is skipped, which
    is the check that stops a malformed tag reaching the GPU and the Release;
    the picture gate itself, and every property that keeps a publish behind
    it, is untouched. It is a real gap under a reading nobody has evidence
    for, and it is the only one this case-folding creates.
12. THIS FILE'S OWN LINT. `shellcheck /ci/*.sh` cannot see a `.py`. The
    `devel-test` stage now runs pyflakes over `/ci/*.py`, which catches
    undefined names and unused imports and NOTHING about whether a property
    is right; release_gate_workflow.bats, which proves each property fails
    when removed, is still the only thing that does that.
13. THE RELEASE PATH DOES NOT PASS THROUGH `main`, AND THIS FILE ONLY GUARDS
    WHAT DOES. This checker runs inside `devel-test`, built by
    `call-docker-build`, which is a REQUIRED status check on `main` with
    `enforce_admins: true` -- so a pull request that breaks it cannot merge.
    That is a real gate and it is worth having. It is also not the release
    trigger. A release is a TAG PUSH, and GitHub runs the workflow file FROM
    THE TAGGED COMMIT: `git tag v9.9.9 <any commit> && git push origin
    v9.9.9` publishes using whatever main.yaml that commit carries, which no
    pull request, no required check and no run of this file ever saw. There
    is no tag ruleset on this repository (verified: /rulesets is empty,
    /tags/protection is 404). So the accurate statement of what this file
    buys is "a main.yaml that reached `main` passed these properties", NOT
    "a published version passed them". Closing that gap needs a tag ruleset,
    which is a repository setting; no amount of work in here can do it.
14. THE ONE PROPERTY THAT IS NOT ABOUT TEXT is
    check_picture_leaves_evidence, and it is the answer to items 3(a) and 13
    rather than another entry in the enumeration. Everything else here asks
    whether main.yaml SAYS the right thing; that question has a floor,
    reached in round 8, when five single-step edits each left a workflow
    this file passed and a Tier B job that went green having sampled no
    frame. The chain -- spec samples a frame, writes an attestation; the
    driver verifies it against this run's commit; the job exposes it; the
    require-picture-evidence job fails on empty; both publishers stand
    behind that job -- fails all five at once, without this file having to
    know any of them exist. It does not make the workflow unforgeable
    (whoever can edit main.yaml can edit those links too, and item 13 still
    stands), but it moves the question from "did the job report success?" to
    "does a frame exist, and is it this commit's frame?".
===========================================================================
"""

import re
import sys
import traceback

import yaml

# --- the named jobs whose ROLE is not derivable ----------------------------
# verify-tag-shape and tier-b-visual-e2e publish nothing; they are gates, so
# no derivation can find them. Everything whose role IS derivable is derived:
# see publishing_jobs().
GATE_JOBS = (
    "call-docker-build",
    "verify-tag-shape",
    "call-release",
    "publish-image",
    "tier-b-visual-e2e",
    # Load-bearing since the evidence chain landed: `continue-on-error: true`
    # here turns a job that FAILED on an empty attestation into one whose
    # conclusion is 'success', which is all `needs.*.result` can see. Adding
    # a job to the release path without adding it here is how that happens,
    # and it happened once already.
    "require-picture-evidence",
)

TIER_B = "tier-b-visual-e2e"

# The gate jobs whose WORK IS ONE EXACT COMMAND, and what that command is.
#
# WHY IDENTITY AND NOT A COUNT. Property 10 asks "is there an unconditional
# step in this job that names something under script/ci/?". That question
# cannot tell tier_b_visual_e2e.sh from derive_image_tag.sh, and it cannot
# tell `bash script/ci/tier_b_visual_e2e.sh` from the same line with `|| true`
# after it. A reviewer walked EIGHT bypasses past the count, all of them
# publishing with no picture ever taken:
#
#   - the driver suffixed with `|| true`, or wrapped in `set +e; ...; exit 0`
#   - the driver replaced by `--help` or `--version`, which exit 0 at once
#   - the work step pointed at a DIFFERENT script/ci/ helper entirely
#   - the real work moved behind an `if:` (as an inline `run:`, a third-party
#     action, or `run: $CMD` with the command in `env:`) while an
#     unconditional `echo` naming `script/ci/` kept the count satisfied
#
# So the property here is not "some step mentions the directory". It is
# "THIS command runs, unconditionally, and no other step in this job invokes
# the same script in some other spelling". Property 10 stays as the broader
# net over every gate and publishing job; this is the identity pin on the two
# jobs whose work is a single named driver.
#
# THE COST, stated so it is a decision and not a surprise: the invocation is
# compared EXACTLY (whitespace-collapsed, nothing else). Adding a legitimate
# argument -- `bash script/ci/tier_b_visual_e2e.sh --retries 2` -- is a
# violation until the new spelling is written HERE. That is the intended
# trade: an argument is exactly how a no-op arrives, so a new one is a change
# to what the gate does and belongs in this table where it can be reviewed.
GATE_WORK_DRIVERS = {
    # The evidence gate. Pinned for the same reason the Tier B driver is:
    # round 10 defeated the inline `if [ -z ... ]` version four ways in one
    # sitting, because "does this shell text fail on empty?" is a question
    # about a Turing-complete language. "Is this job's work exactly this
    # command?" is not.
    "require-picture-evidence": "bash script/ci/require_attestation.sh",
    TIER_B: "bash script/ci/tier_b_visual_e2e.sh",
    "verify-tag-shape": "bash script/ci/derive_image_tag.sh",
}

# A STRING IS NOT AN INVOCATION. The table above is compared against
# `" ".join(step["run"].split())`, and FOUR SIBLING KEYS decide what that
# string actually does. A reviewer walked six mutations past the comparison,
# every one of them publishing with no picture, and in THREE of them the
# pinned `run:` line is untouched -- the diff shows only a `defaults:` block:
#
#   shell: cat {0}              GitHub's documented custom-shell form is
#   shell: bash -n {0}          `command [...options] {0}`. The driver is
#                               PRINTED, or syntax-checked, and never runs,
#                               while the step and the job report 'success'.
#   working-directory: <dir>    the same string, resolved against another
#                               tree -- a fixture holding a stub of the same
#                               path.
#   env: TIER_B_PRODUCER_IMAGE  the driver reads it (and TIER_B_VIEWER_IMAGE,
#                               and TIER_B_BOOT_TIMEOUT) from its
#                               environment, so the "picture" is one of
#                               whatever image the editor chose.
#   defaults.run.<any of those> at JOB or WORKFLOW level, which is how all
#                               three arrive without touching the step at all.
#
# So the property is now "THIS COMMAND RUNS, UNMODIFIED, IN THE EXPECTED
# PLACE" rather than "this string appears". These keys are refused on a step
# that invokes a pinned driver, and `defaults.run` / `env:` are refused on
# the two driver jobs and at workflow level, where they reach them.
#
# THE COST, stated so it is a decision and not a surprise: a legitimate
# `shell:` or `env:` on one of those two steps is a violation until the
# spelling is added HERE, next to the argument trade GATE_WORK_DRIVERS
# already makes. The remedy is always achievable -- put the declaration on a
# job or a step that does not run a pinned driver -- and the refusal is loud.
# The list is deliberately whole-key rather than key-by-key for `defaults`,
# because `defaults.run` has exactly the keys above and enumerating them
# again is the enumeration failure this file keeps writing down.
GATE_WORK_STEP_MODIFIERS = ("shell", "working-directory", "env")

# The one variable a pinned gate job is allowed to be given, per job.
#
# `env:` is refused on these jobs because it sets the knobs a driver reads for
# itself -- that is what makes `TIER_B_PRODUCER_IMAGE` dangerous. But the
# evidence gate's whole input IS an environment variable: the attestation,
# handed down from the Tier B job. Refusing it outright would mean the gate
# could not be given the thing it gates on.
#
# So it is declared here rather than allowed by accident, and the exemption is
# narrow in both directions: only this NAME, and check_picture_leaves_evidence
# separately requires its VALUE to be exactly the attestation reference and
# nothing else -- no `|| 'ok'`, no trailing dot, no concatenation. A name that
# is not in this table is refused exactly as before.
GATE_WORK_DRIVER_ENV = {
    "require-picture-evidence": frozenset(("ATTESTATION",)),
}

# A `--print-<x>` QUERY is the one other spelling a driver job may contain:
# it asks the driver for a value rather than doing the job (this repo's Tier
# B job pulls the producer image the driver names). It used to be recognised
# by `"--print-" in run`, a SUBSTRING over the whole body, which granted any
# unconditional step carrying that literal anywhere a free pass to invoke the
# driver in any spelling at all -- `echo --print-nothing && <driver> --help
# || true`. Now every occurrence of the script in the step must ITSELF be
# invoked with exactly one `--print-<x>` argument.
_PRINT_QUERY_RE = re.compile(r"^--print-[A-Za-z0-9][A-Za-z0-9._-]*$")

# Report-only jobs. They exist to ADD a failure (a blocked release that would
# otherwise be a grey cancelled job on a green-looking run). Nothing may
# `needs:` one: that would make a job whose whole design is to fail loudly
# into something a downstream job waits on, and its always() would then
# propagate where the gate rule forbids a status function.
REPORT_ONLY_JOBS = ("release-blocked-report", "nightly-tier-b-report")

# Permission scopes that let a job leave something PERMANENT behind. A job
# holding one of these at `write` can publish whether or not this file
# recognises the mechanism, which is why permissions are the first and
# broadest publishing signal rather than an afterthought.
PERMANENT_SCOPES = (
    "contents",
    "packages",
    "deployments",
    "pages",
    "id-token",
    "attestations",
)

# Actions and reusable workflows that publish, or that only a publishing job
# has a reason to call.
#
# `docker/build-push-action` is deliberately NOT here: `push: false` is the
# documented way to build and test without pushing, and it is exactly what
# this repo's own build-worker does on every PR. Listing the action would
# report every build job as one that must stand behind the release gate,
# which is a false positive on the most ordinary edit there is. It is derived
# instead by its `push:` input -- see _truthy_push.
#
# `docker/login-action` IS here, on the opposite reasoning: a registry login
# in a job that publishes nothing is not a normal pattern, and a job holding
# registry credentials is one that can publish however its push is spelled.
PUBLISH_USES = (
    "docker/login-action",
    "softprops/action-gh-release",
    "ncipollo/release-action",
    "action-gh-release",
    "release-worker",
    "pypa/gh-action-pypi-publish",
)

# Commands that publish. `--push` on a build is deliberately separate from a
# bare `docker push`: `docker buildx build --push` names neither string the
# text-matching version of this file looked for, and it was one of the
# mutations that walked past it.
#
# THIS IS AN ENUMERATION AND ENUMERATIONS DO NOT CONVERGE. Said plainly here
# and in limitation 4, because three rounds of widening it have each been
# followed by a reviewer naming something else: `docker image push`,
# `buildah push`, `podman push`, `gh api -X POST .../releases`, and -- the one
# that defeated EVERY pattern at once rather than one of them -- a shell line
# continuation, because each of these matches within a single line. A
# publishing command spelled in a way nobody has thought of yet is still not
# derived, and no amount of adding rows changes that. What DOES change it is
# the `permissions:` signal, which is a capability rather than a spelling and
# is why permissions are checked first and broadest.
#
# Line continuations are joined before matching (see _join_continuations), so
# `docker \` + newline + `push ...` is one line by the time it gets here.
PUBLISH_RUN_RE = (
    re.compile(r"\bdocker\s+(?:image\s+)?push\b"),
    re.compile(r"\bdocker\s+compose\s+push\b"),
    re.compile(r"\bdocker\s+manifest\s+push\b"),
    re.compile(
        r"\bdocker\s+(?:buildx\s+)?(?:build|bake)\b[^\n]*(?:\s|^)--push\b"
    ),
    re.compile(r"\b(?:podman|buildah|nerdctl)\s+(?:image\s+)?push\b"),
    re.compile(r"\b(?:podman|nerdctl)\s+manifest\s+push\b"),
    re.compile(r"\bctr\s+(?:images?|i)\s+push\b"),
    re.compile(r"\bgh\s+release\s+(?:create|upload|edit)\b"),
    # A REST write against the releases (or packages) API is a Release cut by
    # hand. Scoped to an explicit write METHOD on purpose: this repo's own
    # publish-image reads `/repos/<r>/releases/tags/v<version>` to refuse a
    # publish with no Release behind it, and that GET must not be derived as
    # a publish -- it sits behind an `if:`, and calling it "the publishing
    # act" would report the guard itself as a violation.
    re.compile(
        r"\bgh\s+api\b(?=[^\n]*(?:-X|--method)[=\s]\s*"
        r"(?:POST|PUT|PATCH|DELETE))(?=[^\n]*\b(?:releases|packages)\b)",
        re.IGNORECASE,
    ),
    re.compile(r"\bnpm\s+publish\b"),
    re.compile(r"\bpnpm\s+publish\b"),
    re.compile(r"\byarn\s+publish\b"),
    re.compile(r"\btwine\s+upload\b"),
    re.compile(r"\bcargo\s+publish\b"),
    re.compile(r"\b(?:oras|crane)\s+(?:push|copy)\b"),
    # `regctl` USED TO SHARE THE ROW ABOVE, and matched nothing real: regctl
    # has no `push` and no `copy` subcommand -- the writes are `regctl image
    # copy|import`, `regctl artifact put`, `regctl manifest put` and `regctl
    # index create`, and `regctl image copy` was confirmed missed. A row that
    # LOOKS like coverage and provides none is worse than an admitted gap,
    # because the name appearing in the table is what stops anyone checking.
    # Written as <known noun> x <write verb> rather than as a list of exact
    # subcommand pairs, so a write verb regctl adds under one of these nouns
    # is covered without another round of naming spellings. Scoped to the
    # WRITE verbs on purpose: `regctl image digest`, `regctl tag ls` and the
    # rest of the read surface are ordinary CI queries, and reporting them
    # would put every registry lookup behind the picture gate.
    #
    # NARROWED IN ONE DIRECTION, said out loud: the old row would have
    # matched a `regctl push` if regctl ever grew one, purely by accident.
    # This does not. That is the same trade every row here makes -- an
    # enumeration is only ever as wide as what someone thought of -- and it
    # buys a row that matches the commands that exist.
    re.compile(
        r"\bregctl\s+(?:artifact|image|index|manifest|tag)\s+"
        r"(?:copy|import|put|create|mod|delete)\b"
    ),
    # A registry login in a job that publishes nothing is not a normal
    # pattern -- the same reasoning that puts docker/login-action in
    # PUBLISH_USES rather than leaving it to the push spelling.
    re.compile(r"\bregctl\s+registry\s+login\b"),
    re.compile(r"\bskopeo\s+copy\b"),
    re.compile(r"\bhelm\s+push\b"),
    re.compile(r"\bcurl\b[^\n]*(?:\s-T\s|--upload-file)"),
)

# The subset of PUBLISH_USES that IS the publishing act rather than a step on
# the way to it. A `docker/login-action` behind an `if:` is a login that did
# not happen; an `action-gh-release` behind an `if:` is a Release that did not
# happen while the job still reports success. Only the second is the job's
# work, so only the second is required to be unconditional.
PUBLISH_STEP_USES = (
    "softprops/action-gh-release",
    "ncipollo/release-action",
    "action-gh-release",
    "pypa/gh-action-pypi-publish",
)

STATUS_FUNCTIONS = ("always", "success", "failure", "cancelled")


# ===========================================================================
# violations
# ===========================================================================
_violations = []


def violation(vid, message):
    """Record a violation under its stable id and print it to stderr."""
    _violations.append(vid)
    sys.stderr.write(
        "check_release_gates: VIOLATION [%s] %s\n" % (vid, message)
    )


def refuse(message):
    """Exit 2: this file could not be read as a workflow at all.

    Distinct from a violation (exit 1) on purpose. A checker that reports
    "invariant holds" for a file it never understood is the same hole it
    exists to close, so an unparseable, empty or job-less workflow is an
    ERROR rather than a vacuous pass.
    """
    sys.stderr.write("check_release_gates: %s\n" % message)
    raise SystemExit(2)


# ===========================================================================
# parsing
# ===========================================================================
class _StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys.

    PyYAML's default is last-wins, silently. A workflow with `if:` twice in
    one job would then be read as whichever came last while a maintainer
    reads whichever came first, and the disagreement is invisible in both
    directions. GitHub rejects duplicate keys; so does this.
    """


def _no_duplicate_keys(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError:  # unhashable key; construct_mapping will report it
            duplicate = False
        if duplicate:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found duplicate key %r" % (key,),
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicate_keys
)


def load_workflow(path):
    """Parse <path>, or exit 2 saying why."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        refuse("cannot read workflow %s (%s)" % (path, exc.strerror or exc))
    try:
        doc = yaml.load(text, Loader=_StrictLoader)
    except yaml.YAMLError as exc:
        refuse(
            "cannot parse workflow %s as YAML: %s"
            % (path, str(exc).replace("\n", " "))
        )
    if not isinstance(doc, dict):
        refuse("%s is not a YAML mapping, so it is not a workflow" % path)
    return doc


def get_on(workflow):
    """The `on:` section.

    YAML 1.1 resolves a bare `on` to the boolean True, which is why the
    quoted `'on':` spelling exists and why reading only one of them reported
    a workflow with no triggers at all.
    """
    for key in (True, "on", "On", "ON"):
        if key in workflow:
            return workflow[key]
    return None


def as_text(value):
    """A YAML scalar as the string GitHub would evaluate.

    `if: false` parses to the boolean False and is a real, falsy condition;
    an absent key and an empty value are both "no condition".
    """
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def as_list(value):
    """A YAML scalar-or-sequence as a list of strings."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [as_text(item) for item in value]
    return [as_text(value)]


# ===========================================================================
# expressions
# ===========================================================================
def unwrap(expr):
    """Strip the `${{ }}` notation, which is not part of the expression."""
    expr = expr.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2].strip()
    return expr


def _scan(expr):
    """Yield (index, char, in_string) over <expr>.

    GitHub expression strings are single-quoted and escape a quote by
    doubling it. Every scan in this file goes through here, because the
    checker that did not have this was defeated by one `(` inside a string.
    """
    i = 0
    n = len(expr)
    while i < n:
        char = expr[i]
        if char == "'":
            yield i, char, True
            i += 1
            while i < n:
                if expr[i] == "'":
                    if i + 1 < n and expr[i + 1] == "'":
                        yield i, expr[i], True
                        yield i + 1, expr[i + 1], True
                        i += 2
                        continue
                    yield i, expr[i], True
                    i += 1
                    break
                yield i, expr[i], True
                i += 1
            continue
        yield i, char, False
        i += 1


def is_balanced(expr):
    """True when parentheses OUTSIDE string literals balance.

    An expression that does not balance cannot be split into terms
    meaningfully, so the callers report it rather than splitting it wrongly
    and reporting the result as a held invariant.
    """
    depth = 0
    for _, char, in_string in _scan(expr):
        if in_string:
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def top_terms(expr, op):
    """Split <expr> at every top-level `||` or `&&`, string-literal aware.

    Depth is what makes this structural rather than a grep: the `||` inside
    `(inputs.run_tier_b || inputs.publish_image_tag != '')` is a nested
    alternative and must not be split out. Quoted text contributes no depth
    and no operators, which is the half the awk version did not have.
    """
    assert op in ("|", "&")
    pair = op * 2
    depth = 0
    out = []
    cur = []
    skip = -1
    for index, char, in_string in _scan(expr):
        if index == skip:
            continue
        if in_string:
            cur.append(char)
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if depth == 0 and char == op and expr[index : index + 2] == pair:
            out.append("".join(cur))
            cur = []
            skip = index + 1
            continue
        cur.append(char)
    out.append("".join(cur))
    return [term.strip() for term in out]


def canon(term):
    """<term> with redundant outer parens and non-literal whitespace removed.

    `needs.x.result == 'success'`, `needs.x.result=='success'` and
    `(needs.x.result  ==  'success')` are one expression written three ways.
    Rejecting two of the three is a false positive, and a checker that
    reports correct edits as violations is one maintainers learn to route
    around -- which is the same board of green checks with extra ceremony.
    """
    term = unwrap(term).strip()
    while term.startswith("(") and term.endswith(")"):
        inner = term[1:-1]
        if not is_balanced(inner):
            break
        term = inner.strip()
    out = []
    for _, char, in_string in _scan(term):
        if in_string or not char.isspace():
            out.append(char)
    return "".join(out)


def canon_key(term):
    """<term> canonicalised AND lower-cased, for comparison against a set.

    EVERY comparison against a closed set of spellings goes through here, and
    never through canon() directly, because the sets below are written in one
    case and the thing being compared may be written in any.

    WHY LOWER-CASE. `if: ALWAYS() && startsWith(github.ref, 'refs/tags/')` on
    call-release, paired with a Tier B work step that cannot fail, was walked
    straight past a version of this file that matched `\\balways\\s*\\(`
    case-sensitively: the whole release invariant, defeated by two capital
    letters. The same case-sensitivity ALSO reported `STARTSWITH(...)` as a
    violation, which is a false positive -- so it failed open for the
    spelling an attacker wants and closed for one a maintainer might write.

    HONESTY ABOUT THE SOURCE. That GitHub's expression function names and
    context names are case-insensitive is what actions/languageservices (the
    parser behind the Actions VS Code extension) implements, and it is widely
    written up, but it is NOT stated in GitHub's public expressions
    reference. This file therefore does not RELY on it being true: matching
    case-insensitively costs nothing and is strictly safer whichever way the
    real evaluator behaves. If GitHub were case-SENSITIVE, `ALWAYS()` would
    be an unknown function and the workflow would fail rather than publish;
    if it is case-INSENSITIVE, this is the only thing that catches it.

    String literals are lower-cased too. GitHub's `==` on strings is
    documented as case-insensitive, so `needs.x.result == 'SUCCESS'` and
    `... == 'success'` are one expression, and folding them together is the
    same decision, not an extra one.
    """
    return canon(term).lower()


# Every set below is written LOWER-CASE and compared against canon_key().
TAG_REF_TESTS = frozenset(
    (
        "startswith(github.ref,'refs/tags/')",
        "github.ref_type=='tag'",
        "'tag'==github.ref_type",
    )
)

TIER_B_SUCCESS_TESTS = frozenset(
    (
        "needs.tier-b-visual-e2e.result=='success'",
        "'success'==needs.tier-b-visual-e2e.result",
    )
)

# The narrow status function, and only it. See publish_image_status_is_narrow.
NOT_CANCELLED_TESTS = frozenset(
    ("!cancelled()", "cancelled()==false", "false==cancelled()")
)

TIER_B_NOT_SUCCESS_TESTS = frozenset(
    (
        "needs.tier-b-visual-e2e.result!='success'",
        "'success'!=needs.tier-b-visual-e2e.result",
    )
)


def is_tag_ref_test(term):
    return canon_key(term) in TAG_REF_TESTS


def is_tier_b_success_test(term):
    return canon_key(term) in TIER_B_SUCCESS_TESTS


def status_functions_in(expr):
    """Every status function called at expression level in <expr>.

    Outside string literals only, so a job name or a commit message
    containing the word `always` is not a status function -- and, equally, a
    status function cannot be hidden inside one.

    CASE-INSENSITIVE, for the reason canon_key() gives at length: matching
    `always` but not `ALWAYS` let `if: ALWAYS()` on call-release defeat the
    entire release invariant. The returned names are always the lower-case
    spellings from STATUS_FUNCTIONS, so callers comparing against `"always"`
    keep working whatever the file said.
    """
    plain = []
    for _, char, in_string in _scan(expr):
        plain.append(" " if in_string else char)
    text = "".join(plain)
    found = []
    for name in STATUS_FUNCTIONS:
        if re.search(r"\b%s\s*\(" % name, text, re.IGNORECASE):
            found.append(name)
    return found


def has_top_level_or(expr):
    """True when <expr> has a `||` at depth 0.

    `&&` binds tighter, so a top-level `||` makes everything else in the
    condition merely one ALTERNATIVE.
    """
    return len(top_terms(expr, "|")) != 1


def has_tier_b_success_conjunct(expr):
    """True when a top-level `&&` term of <expr> IS the tier-b success test."""
    return any(is_tier_b_success_test(term) for term in top_terms(expr, "&"))


# ===========================================================================
# the workflow, read structurally
# ===========================================================================
class Workflow(object):
    def __init__(self, path):
        self.path = path
        self.doc = load_workflow(path)
        jobs = self.doc.get("jobs")
        if not isinstance(jobs, dict) or not jobs:
            refuse("%s declares no jobs" % path)
        self.jobs = {}
        for name, body in jobs.items():
            name = as_text(name)
            if not isinstance(body, dict):
                refuse("%s: job '%s' is not a mapping" % (path, name))
            self.jobs[name] = body
        self.workflow_permissions = self.doc.get("permissions")

    # -- accessors ---------------------------------------------------------
    def names(self):
        return list(self.jobs.keys())

    def has(self, job):
        return job in self.jobs

    def body(self, job):
        return self.jobs.get(job) or {}

    def condition(self, job):
        """<job>'s JOB-LEVEL condition, as GitHub would evaluate it."""
        return unwrap(as_text(self.body(job).get("if")))

    def needs(self, job):
        return as_list(self.body(job).get("needs"))

    def needs_job(self, job, needed):
        return needed in self.needs(job)

    def steps(self, job):
        steps = self.body(job).get("steps")
        if not isinstance(steps, list):
            return []
        return [step for step in steps if isinstance(step, dict)]

    def step_condition(self, step):
        return unwrap(as_text(step.get("if")))

    def runs_on_raw(self, job):
        """<job>'s `runs-on` EXACTLY as written.

        Not as_list()'d: `runs-on` has three valid shapes -- a scalar, a
        sequence of labels, and a MAPPING with `group:` / `labels:` -- and
        flattening the mapping to `str(dict)` reported the documented
        runner-group syntax as a job that had left the GPU runner. See
        runs_on_variants.
        """
        return self.body(job).get("runs-on")

    def permissions(self, job):
        """<job>'s EFFECTIVE permissions: its own, else the workflow's.

        Workflow-level `permissions:` is not decoration -- it is the grant
        every job without its own block runs with, and reading only job-level
        blocks meant a workflow that handed write to everything looked
        read-only to this file.
        """
        own = self.body(job).get("permissions")
        if own is None:
            return self.workflow_permissions
        return own


def _strip_shell_comments(text):
    """<text> with `# ...` removed, for a `run:` body.

    A block scalar keeps its `#` -- YAML does not treat it as a comment, but
    the shell does, so `run: |` / `true  # bash script/ci/x.sh` runs nothing
    while still naming the helper. Approximate rather than exact: a `#` that
    opens a line or follows whitespace ends the line. A `#` inside a quoted
    shell string is therefore treated as a comment; see limitation 3.
    """
    out = []
    for line in text.split("\n"):
        out.append(re.sub(r"(^|\s)#.*$", r"\1", line))
    return "\n".join(out)


_MATRIX_RUNS_ON_RE = re.compile(
    r"\$\{\{\s*matrix\.([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}"
)


def runs_on_variants(wf, job):
    """(every label set <job> could run on, None), or (None, why not).

    `runs-on` has more than one legal shape, and reading only the two this
    repo happens to use reported the others as a job that had left the GPU
    runner -- a false positive on a valid edit, which is the kind of noise
    that gets a check switched off:

      - a SEQUENCE, `[self-hosted, gpu]`: one variant, those labels;
      - a SCALAR, `ubuntu-latest`: one variant, one label;
      - a MAPPING, `{group: gpu-hosts, labels: [self-hosted, gpu]}`: this is
        documented GitHub syntax for picking a runner GROUP as well as
        labels, and it will be written here the day the org moves the GPU
        host into a group;
      - `${{ matrix.runner }}`: resolved against this job's
        `strategy.matrix`, and EVERY value it could take must satisfy the
        caller -- a matrix with one GPU entry and one hosted entry means the
        gate runs on a hosted runner for half its variants.

    A `group:` with no `labels:` is NOT resolvable here: which machines are
    in a runner group is repo/org settings, which limitation 6 says this file
    cannot see. That comes back as a problem, not as a silent pass.
    """
    raw = wf.runs_on_raw(job)
    if raw is None:
        return None, "runs-on is absent"
    if isinstance(raw, dict):
        if "labels" in raw:
            return [as_list(raw.get("labels"))], None
        if "group" in raw:
            return None, (
                "runs-on names a runner group ('%s') and no labels:. Which "
                "machines are in a group is a repo/org SETTING, which this "
                "file cannot read -- add 'labels: [self-hosted, gpu]' "
                "alongside the group so the requirement is in the workflow"
                % as_text(raw.get("group"))
            )
        return None, "runs-on is a mapping with neither labels: nor group:"
    if isinstance(raw, (list, tuple)):
        return [as_list(raw)], None

    text = as_text(raw).strip()
    match = _MATRIX_RUNS_ON_RE.fullmatch(text)
    if match:
        name = match.group(1)
        strategy = wf.body(job).get("strategy")
        matrix = strategy.get("matrix") if isinstance(strategy, dict) else None
        if not isinstance(matrix, dict) or name not in matrix:
            return None, (
                "runs-on is '%s' but this job's strategy.matrix declares no "
                "'%s', so the runner it lands on is not determined here"
                % (text, name)
            )
        values = matrix.get(name)
        if not isinstance(values, (list, tuple)) or not values:
            return None, (
                "runs-on is '%s' and strategy.matrix.%s is not a non-empty "
                "list" % (text, name)
            )
        variants = []
        for value in values:
            if isinstance(value, dict):
                if "labels" not in value:
                    return None, (
                        "runs-on is '%s' and one strategy.matrix.%s entry is "
                        "a mapping with no labels:" % (text, name)
                    )
                variants.append(as_list(value.get("labels")))
            else:
                variants.append(as_list(value))
        return variants, None
    if "${{" in text:
        return None, (
            "runs-on is the expression '%s', whose value is decided outside "
            "this file (an input, an env, a reusable-workflow caller), so the "
            "runner it lands on is not determined here" % text
        )
    return [[text]], None


def _join_continuations(text):
    """<text> with shell line continuations folded into one line.

    `docker \\` + newline + `push ghcr.io/...` is ONE command. Every pattern
    in PUBLISH_RUN_RE matches within a line, so without this a backslash
    defeated all of them at once -- not one row of the table, the whole
    table.
    """
    return re.sub(r"\\\n[ \t]*", " ", text)


def publish_search_text(step):
    """The text of <step> to search for PUBLISHING commands.

    RAW. Shell comments are deliberately NOT stripped here, and that is the
    opposite of what step_text() does for gate WORK, because the two fail in
    opposite directions:

      - for gate work, treating a commented-out line as real work would let
        `run: true  # bash script/ci/x.sh` count as the gate;
      - for publishing, treating a real command as a comment REMOVES the
        publish signal, and a job that is not derived as publishing is not
        required to stand behind the picture gate at all.

    `run: echo "build #1 done" ; docker push ghcr.io/...` is the whole bypass:
    a `#` inside a double-quoted shell string is not a comment to the shell,
    the strip heuristic ate the rest of the line, and the push vanished. So
    this searches the raw body and ACCEPTS the false positive in the other
    direction -- a genuinely commented-out `docker push` marks the job as one
    that must stand behind the gate, which costs a `needs:` line and never a
    missed publish.

    STEP-LEVEL `env:` VALUES ARE INCLUDED. `env: CMD: docker push ...` with
    `run: eval "$CMD"` is indirection this file cannot follow at the `run:`
    end, but it can see the command where it is written. Same trade: a
    variable that merely NAMES a push marks the step as publishing.
    Job-level `env:` is read separately, by publishing_reason, so its reason
    message points at the job rather than at an arbitrary step.
    """
    parts = []
    step_env = step.get("env")
    if isinstance(step_env, dict):
        for value in step_env.values():
            parts.append(as_text(value))
    run = step.get("run")
    if run is not None:
        parts.append(as_text(run))
    return _join_continuations("\n".join(parts))


def step_text(step):
    """The parts of <step> that say what it DOES."""
    parts = []
    run = step.get("run")
    if run is not None:
        parts.append(_strip_shell_comments(as_text(run)))
    uses = step.get("uses")
    if uses is not None:
        parts.append(as_text(uses))
    return "\n".join(parts)


# Tokens that may precede the driver path and still leave it the thing being
# RUN: an interpreter, an option to one, or a leading VAR=value assignment.
_INTERPRETERS = frozenset(("bash", "sh", "dash", "ksh", "zsh", "command", "exec"))
# Commands that READ a path without changing it. A gate job naming a file
# under script/ci/ as an argument to one of these is doing something
# legitimate -- linting it, listing it, running this very checker over the
# workflow -- and reporting it taught nothing except "do not mention the
# directory".
#
# This is a TABLE ON PURPOSE, in the same spirit as GATE_WORK_DRIVERS: the
# round-9 reviewer's complaint was not that read-only mentions were refused,
# it was that there was nowhere to declare one. Adding a command here is a
# reviewable diff. Anything absent is still reported, which is the direction
# a gate should fail in -- a false alarm costs a line in this tuple, a missed
# mutation costs a release nobody looked at.
# Interpreters: read-only toward the path they are given to RUN, and only
# toward that one -- see runs_the_path in driver_occurrences.
_SCRIPT_RUNNERS = frozenset(("python3", "python", "node", "ruby", "perl"))

_READ_ONLY_COMMANDS = frozenset(
    (
        "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep",
        "ls", "stat", "file", "wc", "md5sum", "sha256sum", "cmp", "diff",
        "echo", "printf", "shellcheck", "pyflakes", "test", "[",
        # NOT here, though they look like they belong: `shfmt -w` rewrites in
        # place, and `python3 <script> <path>` does whatever <script> says. A
        # command that can write is not a read-only mention, however often it
        # is used as one.
    )
)
_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_REDIRECT_RE = re.compile(r"^\d*[<>]")
# Command boundaries. `(` and a backtick open a new command; the closers end
# one. Quotes are NOT boundaries -- they are stripped from tokens instead, so
# that `"$(bash <driver> --print-x)"` reads as one command, not three.
_CMD_OPEN_RE = re.compile(r"\|\||&&|[;|&\n(`]")
_CMD_CLOSE_RE = re.compile(r"\|\||&&|[;|&\n)`]")
# Anything under the driver's directory. The selection test used to be the
# driver's exact path as a SUBSTRING, which is why round 8's `sed -i
# '1a exit 0' script/ci/*.sh` and `script/ci//tier_b_visual_e2e.sh` were never
# examined at all: neither string contains the literal path, though every
# shell resolves both to it. Selecting on the directory catches the glob, the
# redundant separator, and any sibling script reached the same way -- and
# costs nothing, because a gate job has no business writing in there.
_CD_INTO_CI_RE = re.compile(
    r"(?:^|[;&|\n])\s*cd\s+[\"\']?\.?/?script/ci\b"
)


def _CI_ENV_NAME_RE(name):
    """Match the NAME of a runner file variable, however it is expanded.

    Round 9 tested `"$X" in body or "${X}" in body`. Round 10's reviewer got
    past that with `${X:?}`, `${X:-/dev/null}`, `${X#}`, `v=X; "${!v}"` and
    `"$(printenv X)"` -- and then executed the resulting shim against the real
    driver, which printed "a real browser rendered a real, non-black frame"
    having rendered nothing. Enumerating expansion syntax is the same losing
    game as enumerating path spellings.
    
    Every one of those forms contains the bare word. So match the word, not a
    spelling of the expansion. A gate job that so much as names GITHUB_PATH,
    GITHUB_ENV or GITHUB_OUTPUT outside its pinned work step is reported --
    including in a comment, which costs a rename and buys not having to think
    about shell syntax again.
    """
    return re.compile(r"\b%s\b" % re.escape(name))


def normalise_paths(text):
    """Collapse the spellings a shell resolves but a substring test does not.

    `script//ci/x.sh` and `script/./ci/x.sh` name the same file as
    `script/ci/x.sh`, and every shell agrees. A literal substring test does
    not, which is how round 8's `script/ci//tier_b_visual_e2e.sh` got in --
    and fixing only THAT spelling left `script//ci/` and `script/./ci/`,
    which is what round 9's reviewer walked in through. Normalise once,
    before any question is asked about a path, rather than adding a spelling
    each time somebody finds one.
    """
    text = re.sub(r"/\./", "/", text)
    return re.sub(r"/{2,}", "/", text)


_CI_PATH_RE = re.compile(r"[A-Za-z0-9_./*?\[\]-]*script/ci/[A-Za-z0-9_./*?\[\]-]*")


def _command_segment(text, start, end):
    """The single command containing text[start:end]."""
    seg_start = 0
    for match in _CMD_OPEN_RE.finditer(text[:start]):
        seg_start = match.end()
    match = _CMD_CLOSE_RE.search(text[end:])
    seg_end = end + (match.start() if match else len(text) - end)
    return text[seg_start:seg_end], start - seg_start


def _tokens(fragment):
    """Whitespace tokens with surrounding quotes stripped."""
    return [tok.strip("\"'") for tok in fragment.split() if tok.strip("\"'")]


def driver_occurrences(text, script):
    """Classify every mention of <script>: was it RUN, or done something to?

    The predecessor of this function asked only "what follows the path?" and
    called every answer an invocation. Review round 8 walked straight through
    that: `run: ': > script/ci/tier_b_visual_e2e.sh --print-x'` truncates the
    driver to zero bytes, and because a `--print-<x>` token happened to follow
    the path, the whole step was waved through as a harmless query. The step
    that does the SAME THING without the trailing token was correctly
    reported -- so one appended token was the entire difference between a
    blocked edit and a published one.

    The fix is to read what comes BEFORE. A path is invoked when it is the
    command: first token of its command, or preceded only by an interpreter,
    an option to one, or a leading VAR=value assignment. Anything else --
    `sed -i ... <path>`, `: > <path>`, `cp /dev/null <path>`, `echo x > <path>`
    -- is something being done TO the driver, and is reported.

    Returns a list of (kind, detail) pairs where kind is "invocation" (detail
    is the argument list, redirections dropped) or "mutation" (detail is the
    command, for the message).
    """
    text = normalise_paths(text)
    found = []
    seen = set()
    # First the directory sweep: any path under script/ci/ that something is
    # done TO. This is where the glob and the double-separator spellings are
    # caught, and it deliberately does not care which file they name.
    for match in _CI_PATH_RE.finditer(text):
        segment, offset = _command_segment(text, match.start(), match.end())
        before = _tokens(segment[:offset])
        while before and _ASSIGNMENT_RE.match(before[0]):
            before.pop(0)
        if all(
            tok in _INTERPRETERS or tok == "env" or tok.startswith("-")
            for tok in before
        ):
            continue  # invoked, not mutated; the exact-path pass below judges it
        # A read-only command naming the path is a mention, not a mutation --
        # unless a redirection points AT the path, which is how `echo x >
        # <driver>` overwrites it while `echo` sits in this table.
        command = next(
            (tok for tok in before if not _ASSIGNMENT_RE.match(tok)), ""
        )
        redirected = bool(before) and _REDIRECT_RE.match(before[-1]) is not None
        # The SPAN, not the start. _CI_PATH_RE swallows any prefix the path
        # carries (./ , $PWD/ , ../), so its match begins to the LEFT of the
        # driver path -- and the exact-path pass below, matching only the path
        # itself, lands on a different offset. Recording just the start meant
        # `shellcheck ./script/ci/<driver>` was skipped here and then
        # re-classified as a mutation there: a read-only mention reported as a
        # rewrite, inside the fix whose own comment forbids exactly that.
        span = range(match.start(), match.end())
        # An INTERPRETER is read-only toward a path only when that path is
        # what it runs: `python3 script/ci/check_release_gates.py` executes
        # the named file, while `python3 /tmp/p.py script/ci/<driver>` hands
        # the driver to arbitrary code as data. Position decides, not the
        # command's name -- which is why python3 cannot simply sit in the
        # read-only table.
        runs_the_path = (
            command in _SCRIPT_RUNNERS
            and [tok for tok in before if not tok.startswith("-")][-1:] == [command]
        )
        if (command in _READ_ONLY_COMMANDS or runs_the_path) and not redirected:
            seen.update(span)
            continue
        seen.update(span)
        found.append(("mutation", " ".join(segment.split())[:160]))

    for match in re.finditer(re.escape(script), text):
        if match.start() in seen:
            continue
        segment, offset = _command_segment(text, match.start(), match.end())
        before = _tokens(segment[:offset])
        after = _tokens(segment[offset + len(script):])

        while before and _ASSIGNMENT_RE.match(before[0]):
            before.pop(0)
        # `env` with its own options, then the interpreter, then options.
        invoked = all(
            tok in _INTERPRETERS or tok == "env" or tok.startswith("-")
            for tok in before
        )
        if invoked:
            # A trailing redirection is not an argument to the driver:
            # `<driver> --print-producer-image 2>/dev/null` is still a bare
            # query, and round 8 rejected it -- new noise on a correct edit,
            # which is the failure mode this file argues against.
            found.append(
                ("invocation", [tok for tok in after if not _REDIRECT_RE.match(tok)])
            )
        else:
            found.append(("mutation", " ".join(segment.split())[:160]))
    return found


def is_print_query(args):
    """True when <args> is exactly one `--print-<x>` argument."""
    return len(args) == 1 and _PRINT_QUERY_RE.match(args[0]) is not None


def step_label(step):
    for key in ("name", "uses", "run", "id"):
        if step.get(key) is not None:
            return " ".join(as_text(step[key]).split())[:120]
    return "<unnamed step>"


def _truthy_push(value):
    """True when a `push:` input could be true at run time.

    `push: true` is the literal the text-matching version looked for.
    `push: ${{ ... }}` is an ordinary spelling that could be true on any run,
    and it was one of the mutations that walked past that version.
    """
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    text = as_text(value).strip()
    if not text:
        return False
    return text.lower() not in ("false", "0", "no", "off")


def publishing_reason(wf, job):
    """Why <job> can put something PERMANENT somewhere, or None.

    DERIVED, not listed. A name list only knows the jobs that existed when it
    was written, and a `publish-image-hotfix:` that logs in to GHCR and
    pushes with no gate at all was caught by nothing while one was in force.
    """
    perms = wf.permissions(job)
    if isinstance(perms, str):
        if perms.strip() == "write-all":
            return "permissions: write-all"
    elif isinstance(perms, dict):
        for scope, level in perms.items():
            if as_text(scope) in PERMANENT_SCOPES and as_text(level) == "write":
                return "permissions: %s: write" % as_text(scope)

    body = wf.body(job)
    job_uses = as_text(body.get("uses"))
    for marker in PUBLISH_USES:
        if marker in job_uses:
            return "uses: %s" % job_uses

    # Job-level `env:` once, with its own reason. Folding it into every step's
    # search would report "step 'Checkout' runs \\bdocker\\s+push\\b" about a
    # command written twenty lines above the steps, which sends a maintainer
    # to the wrong place.
    job_env = body.get("env")
    if isinstance(job_env, dict):
        for name, value in job_env.items():
            text = _join_continuations(as_text(value))
            for pattern in PUBLISH_RUN_RE:
                if pattern.search(text):
                    return "job-level env %s matches %s" % (
                        as_text(name),
                        pattern.pattern,
                    )

    for step in wf.steps(job):
        uses = as_text(step.get("uses"))
        for marker in PUBLISH_USES:
            if marker in uses:
                return "step '%s' uses %s" % (step_label(step), marker)
        with_block = step.get("with")
        if isinstance(with_block, dict) and _truthy_push(
            with_block.get("push")
        ):
            return "step '%s' passes push: %s" % (
                step_label(step),
                as_text(with_block.get("push")),
            )
        run = publish_search_text(step)
        for pattern in PUBLISH_RUN_RE:
            if pattern.search(run):
                return "step '%s' runs %s" % (step_label(step), pattern.pattern)
    return None


def publishing_step_reason(step):
    """Why <step> IS the publishing act, or None.

    Narrower than publishing_reason: a registry login or a write permission
    says a job COULD publish, which is what decides whether it must stand
    behind the gate. This says a step DOES publish, which is what decides
    whether it may be skipped.
    """
    uses = as_text(step.get("uses"))
    for marker in PUBLISH_STEP_USES:
        if marker in uses:
            return "uses %s" % marker
    with_block = step.get("with")
    if isinstance(with_block, dict) and _truthy_push(with_block.get("push")):
        return "passes push: %s" % as_text(with_block.get("push"))
    # Step-level env only, NOT the job's: a job-level `env:` naming a push
    # says the JOB can publish (which publishing_reason uses), but it does
    # not make every step in that job the publishing act, and reporting each
    # guarded step as one would be a false positive on every diagnostic step
    # in a publishing job.
    run = publish_search_text(step)
    for pattern in PUBLISH_RUN_RE:
        if pattern.search(run):
            return "runs %s" % pattern.pattern
    return None


def publishing_jobs(wf):
    """Every job that can publish, in file order, with the reason."""
    out = []
    for job in wf.names():
        reason = publishing_reason(wf, job)
        if reason is not None:
            out.append((job, reason))
    return out


def carries_continue_on_error(wf, job):
    """Where <job> turns a gate into a suggestion, or None.

    `continue-on-error: false` is the DEFAULT written out loud and is not a
    violation. The text-matching version reported it as one, which is the
    false-positive half of the same mistake.
    """
    body = wf.body(job)
    if _truthy_push(body.get("continue-on-error")):
        return "job-level continue-on-error: %s" % as_text(
            body.get("continue-on-error")
        )
    for step in wf.steps(job):
        if _truthy_push(step.get("continue-on-error")):
            return "step '%s' carries continue-on-error: %s" % (
                step_label(step),
                as_text(step.get("continue-on-error")),
            )
    return None


# GitHub's tag filter patterns are not shell globs and not regexes: `*` is any
# run of non-`/` characters, `?` is one, `+` means one-or-more of the
# preceding character, `[]` is a character class, and `.` is a LITERAL dot.
def glob_to_regex(glob):
    out = ["^"]
    in_class = False
    for char in glob:
        if in_class:
            out.append(char)
            if char == "]":
                in_class = False
            continue
        if char == "[":
            in_class = True
            out.append(char)
        elif char == "*":
            out.append("[^/]*")
        elif char == "?":
            out.append("[^/]")
        elif char == "+":
            out.append("+")
        elif char in ".(){}|^$\\":
            out.append("\\" + char)
        else:
            out.append(char)
    out.append("$")
    return "".join(out)


def tag_trigger_globs(wf):
    on = get_on(wf.doc)
    if not isinstance(on, dict):
        return []
    push = on.get("push")
    if not isinstance(push, dict):
        return []
    return as_list(push.get("tags"))


def tag_trigger_path_filters(wf):
    """The `paths:` / `paths-ignore:` keys under `on.push`, if any."""
    on = get_on(wf.doc)
    if not isinstance(on, dict):
        return []
    push = on.get("push")
    if not isinstance(push, dict):
        return []
    return [key for key in ("paths", "paths-ignore") if key in push]


def tag_glob_matches(globs, tag):
    """True when <tag> reaches the workflow through <globs>.

    NEGATIONS ARE HONOURED. A pattern starting with `!` EXCLUDES what it
    matches, and later patterns override earlier ones. Without this case a
    single appended `- '!v[0-9]+.[0-9]+.[0-9]+-*'` silently excluded every
    release candidate -- no picture gate, no Release, no image, and no signal
    that anything was meant to happen -- while the property above it, whose
    own comment says PRESENCE IS NOT REACHABILITY, passed because the list
    still had items in it and one of them still matched `v1.2.3`.

    A list of nothing but negations matches nothing, which is what GitHub
    does too (it requires at least one positive pattern) and is reported as
    the unreachable trigger it is.
    """
    matched = False
    for glob in globs:
        negated = glob.startswith("!")
        pattern = glob[1:] if negated else glob
        try:
            if re.match(glob_to_regex(pattern), tag):
                matched = not negated
        except re.error:
            continue
    return matched


# ===========================================================================
# the properties
# ===========================================================================
def check(wf):
    publish_if = wf.condition("publish-image")
    release_if = wf.condition("call-release")
    tier_b_if = wf.condition(TIER_B)

    published = publishing_jobs(wf)
    published_names = [name for name, _ in published]

    # --- 0. every condition in the file is a well-formed expression -------
    # An expression whose parentheses do not balance outside its string
    # literals cannot be split into terms, so every structural property below
    # it would be asserted against a mis-split condition and reported as
    # held. GitHub would fail such a workflow at parse time; so does this,
    # rather than guessing.
    for job in wf.names():
        conditions = [("job-level if", wf.condition(job))]
        for step in wf.steps(job):
            conditions.append(
                ("step '%s' if" % step_label(step), wf.step_condition(step))
            )
        for where, expr in conditions:
            if expr and not is_balanced(expr):
                violation(
                    "condition-is-a-well-formed-expression",
                    "job '%s': %s does not have balanced parentheses outside "
                    "its string literals, so it cannot be split into terms and "
                    "nothing below can be asserted about it. if: %s"
                    % (job, where, expr),
                )

    # --- 1. the publish is wired to the picture gate ----------------------
    # MEMBERSHIP, not substring: a job merely NAMED after the gate (an
    # always()-gated `tier-b-visual-e2e-summary`) does not count.
    if not wf.needs_job("publish-image", TIER_B):
        violation(
            "publish-image-needs-tier-b",
            "publish-image does not have %s as an ITEM of its needs, so an "
            "image can be pushed for a commit whose picture was never "
            "verified. needs: %s"
            % (TIER_B, wf.needs("publish-image") or "<absent>"),
        )

    # --- 2. ... and requires it to have SUCCEEDED, not merely not-failed --
    # Both halves are required. The requirement must be a MANDATORY TOP-LEVEL
    # CONJUNCT, and the condition must have no top-level `||` for it to be an
    # alternative of -- `(gate || inputs.publish_image_tag != '')` still
    # CONTAINS the requirement, and publishes without it.
    if has_top_level_or(publish_if):
        violation(
            "publish-image-gate-is-not-optional",
            "publish-image's condition has a top-level '||', so every gate in "
            "it is merely one ALTERNATIVE -- '&&' binds tighter, and the other "
            "side of that '||' publishes on its own. if: %s"
            % (publish_if or "<absent>"),
        )

    if not has_tier_b_success_conjunct(publish_if):
        violation(
            "publish-image-requires-tier-b-success",
            "publish-image's condition has no MANDATORY top-level conjunct "
            "requiring the picture gate to have succeeded; with its "
            "!cancelled() a SKIPPED gate would no longer stop the push. Write "
            "it as one top-level '&&' term spelled "
            "\"needs.%s.result == 'success'\" (or that with the operands "
            "reversed); whitespace and redundant parentheses do not matter, a "
            "term nested inside a '||' does. if: %s"
            % (TIER_B, publish_if or "<absent>"),
        )

    # --- 2b. and the only status function it carries is the narrow one ----
    # publish-image needs `!cancelled()`: call-release is legitimately skipped
    # on both dispatch paths, and without a status function a skipped need
    # would skip this job. The PROPERTY is "nothing here may be true in a
    # cancelled run except that one narrow test" -- not "the token always()
    # must not appear". `!failure()` is also true in a cancelled run, and
    # banning always() BY NAME let it through under another name.
    narrow = [
        term
        for term in top_terms(publish_if, "&")
        if canon_key(term) in NOT_CANCELLED_TESTS
    ]
    wide = [
        term
        for term in top_terms(publish_if, "&")
        if canon_key(term) not in NOT_CANCELLED_TESTS
        and status_functions_in(term)
    ]
    if wide:
        violation(
            "publish-image-status-function-is-narrow",
            "publish-image's condition uses a status function that is true in "
            "a CANCELLED run: %s. It may carry !cancelled() as a mandatory "
            "top-level conjunct and nothing else -- always() and !failure() "
            "are both true when the run is cancelled, and a cancelled picture "
            "gate (evicted from the GPU concurrency group as a pending member) "
            "is a documented, recurring case here. if: %s"
            % ("; ".join(wide), publish_if or "<absent>"),
        )
    elif not narrow and status_functions_in(publish_if):
        violation(
            "publish-image-status-function-is-narrow",
            "publish-image's condition carries a status function that is not a "
            "mandatory top-level !cancelled(). if: %s"
            % (publish_if or "<absent>"),
        )

    # --- 3. the Release is wired to the picture gate too ------------------
    if not wf.needs_job("call-release", TIER_B):
        violation(
            "call-release-needs-tier-b",
            "call-release does not have %s as an ITEM of its needs, so a "
            "GitHub Release can be cut for a commit whose picture was never "
            "verified. needs: %s"
            % (TIER_B, wf.needs("call-release") or "<absent>"),
        )

    # --- 4. ... by DEFAULT skip propagation, which a status function kills -
    # call-release's condition deliberately carries no status function. That
    # ABSENCE is what keeps GitHub's default rule ("a job is skipped when a
    # job it needs did not succeed") in force, which is what makes an
    # unavailable GPU runner block the release instead of being waved through.
    for name in status_functions_in(release_if):
        violation(
            "call-release-carries-no-status-function",
            "call-release's condition contains '%s()'. A status function "
            "overrides GitHub's default skip propagation, so a SKIPPED %s "
            "would stop blocking the Release. if: %s"
            % (name, TIER_B, release_if),
        )

    # --- 5. no gate may be advisory ---------------------------------------
    # Over the named gate jobs AND every derived publishing job, so a job
    # invented after GATE_JOBS was written cannot opt out by not being on it.
    for job in sorted(set(GATE_JOBS) | set(published_names)):
        if not wf.has(job):
            violation(
                "gate-job-is-defined",
                "gate job '%s' is not defined in %s" % (job, wf.path),
            )
            continue
        where = carries_continue_on_error(wf, job)
        if where:
            violation(
                "gate-job-has-no-continue-on-error",
                "gate job '%s' carries continue-on-error, which turns a gate "
                "into a suggestion: %s" % (job, where),
            )

    # --- 6. a report-only job may only ADD a failure ----------------------
    for job in wf.names():
        for report in REPORT_ONLY_JOBS:
            if wf.needs_job(job, report):
                violation(
                    "no-job-needs-a-report-only-job",
                    "job '%s' needs the report-only job '%s'. Report-only jobs "
                    "use always() and exist to add a failure; nothing may "
                    "depend on one." % (job, report),
                )

    # --- 6b. ... and neither may anything else that is status-gated -------
    # Property 6 is a NAME LIST and only knows today's two report jobs. The
    # rule underneath is not about their names: a job whose own `if:` carries
    # a status function runs on paths where ITS needs did not succeed, so
    # depending on one imports exactly the escape the gate rule forbids.
    for job in wf.names():
        for need in wf.needs(job):
            if not wf.has(need):
                violation(
                    "needs-name-a-job-that-exists",
                    "job '%s' needs '%s', which is not a job in %s"
                    % (job, need, wf.path),
                )
                continue
            need_if = wf.condition(need)
            for name in status_functions_in(need_if):
                violation(
                    "no-job-needs-a-status-gated-job",
                    "job '%s' needs '%s', whose own condition contains "
                    "'%s()'. A status function makes that job run on paths "
                    "where ITS needs did not succeed, so waiting on it imports "
                    "the escape the picture-gate rule forbids. if: %s"
                    % (job, need, name, need_if),
                )

    # --- 7. a tag push starts this workflow at all ------------------------
    globs = tag_trigger_globs(wf)
    if not globs:
        violation(
            "workflow-triggers-on-tag-push",
            "on.push.tags declares no patterns, so a tag push does not start "
            "this workflow and the picture gate never runs for a release. "
            "(Both `on:` and the YAML-1.1-safe `'on':` spelling are read; this "
            "is about the patterns, not the key.)",
        )
    else:
        # A `paths:` / `paths-ignore:` filter alongside `tags:` is REFUSED
        # rather than interpreted. Whether GitHub evaluates a path filter for
        # a TAG push is not something this file can settle from the workflow
        # text, and the two readings differ in the direction that matters: if
        # it is evaluated, `paths: ['does/not/exist/**']` stops every tag push
        # from starting this workflow -- no picture gate, no Release -- while
        # the tag patterns below still match perfectly. So the filter is a
        # violation with a fix rather than a guess.
        #
        # THE REMEDY HAS TO BE ACHIEVABLE. This message used to offer "split
        # the tag trigger into its own `on.push` entry", and there is no such
        # thing: `on.push` is a single YAML key and a second one is a
        # duplicate key, which GitHub rejects and _StrictLoader refuses. The
        # rule was right and failed closed; the sentence sent the operator to
        # do something that cannot be done, which is the same
        # provably-false-diagnostic failure the entrypoint helpers were
        # rewritten for. The two things that CAN be done are below.
        for key in tag_trigger_path_filters(wf):
            violation(
                "tag-trigger-has-no-path-filter",
                "on.push carries a '%s:' filter alongside 'tags:'. A path "
                "filter that matches nothing stops a tag push from starting "
                "this workflow at all, and this checker cannot evaluate it "
                "against a commit it does not have -- so the tag patterns "
                "below can all match while nothing runs. Either drop the "
                "'%s:' filter from on.push entirely, or move the "
                "path-filtered work into a SEPARATE workflow file that has "
                "no 'tags:' trigger, leaving this one's push trigger "
                "unfiltered. (There is no second 'on.push' to split into: it "
                "is one key, and a duplicate is refused here and by GitHub.)"
                % (key, key),
            )
        # PRESENCE IS NOT REACHABILITY: `- 'never-matches-anything'` is a
        # sequence with items in it, and it starts no workflow for any real
        # tag. So is `- '!v[0-9]+.[0-9]+.[0-9]+-*'`, which is a NEGATION and
        # excludes every rc -- see tag_glob_matches. Both shapes this repo
        # cuts are tried, because the incident behind the rule (#70) was an
        # rc.
        for probe in ("v1.2.3", "v1.2.3-rc1"):
            if not tag_glob_matches(globs, probe):
                violation(
                    "tag-globs-match-a-real-version",
                    "no on.push.tags pattern matches '%s', so pushing that tag "
                    "starts no workflow: no picture gate, no Release, no "
                    "image, and no signal that anything was meant to "
                    "happen. Patterns: %s" % (probe, " ".join(globs)),
                )

    # --- 8. ... and reaches the picture gate on EVERY tag push ------------
    if not tier_b_if:
        violation(
            "tier-b-reachable-on-every-tag-push",
            "%s has no job-level condition to check; is the job still there?"
            % TIER_B,
        )
    else:
        if len(top_terms(tier_b_if, "&")) != 1:
            violation(
                "tier-b-reachable-on-every-tag-push",
                "%s's condition has a top-level '&&', so it is no longer true "
                "for every tag push. if: %s" % (TIER_B, tier_b_if),
            )
        if not any(is_tag_ref_test(term) for term in top_terms(tier_b_if, "|")):
            violation(
                "tier-b-reachable-on-every-tag-push",
                "%s's condition has no bare tag-ref test as a top-level "
                "alternative, so a tag push can reach the Release without the "
                "picture gate. Accepted spellings are "
                "\"startsWith(github.ref, 'refs/tags/')\", "
                "\"github.ref_type == 'tag'\" and that with the operands "
                "reversed; whitespace and redundant parentheses do not matter. "
                "Anything else must be added to TAG_REF_TESTS so this stays a "
                "check on MEANING rather than on wording. if: %s"
                % (TIER_B, tier_b_if),
            )

    # --- 9. the one need that must never be skipped -----------------------
    # tier-b-visual-e2e needs verify-tag-shape, and a SKIPPED need skips its
    # dependent. verify-tag-shape carries no job-level `if:` precisely so it
    # can never be skipped; the tag check is guarded per-step instead.
    if wf.body("verify-tag-shape").get("if") is not None:
        violation(
            "verify-tag-shape-has-no-job-level-if",
            "verify-tag-shape has a job-level 'if:' (%s). It is a need of the "
            "picture gate, and a skipped need skips its dependent, so this job "
            "must always run. Guard the tag check per-step instead."
            % (wf.condition("verify-tag-shape") or "<empty>"),
        )

    # --- 10. a gate job's WORK may not be conditionally skipped -----------
    # A job's `result` is all a `needs:` or a `needs.*.result` check can see,
    # so a job that RUNS but does NOTHING reports success and satisfies every
    # property above. In a gate job, a step that runs one of this repo's
    # `script/ci/` helpers IS the job's work and must be unconditional.
    #
    # The scope is GATE_JOBS plus the DERIVED publishing jobs, which is what
    # README.md and doc/test/TEST.md have always said it was. It used to be
    # GATE_JOBS alone.
    for job in sorted(set(GATE_JOBS) | set(published_names)):
        if not wf.has(job):
            continue
        work_steps = 0
        for step in wf.steps(job):
            text = step_text(step)
            if "script/ci/" not in text:
                continue
            # A `--print-<something>` invocation asks the helper a question;
            # it is not the job's work, so it does not satisfy the "there is
            # still work here" count. It is still required to be
            # unconditional -- a skipped query fails the step that uses it.
            if "--print-" not in text:
                work_steps += 1
            step_if = wf.step_condition(step)
            if not step_if:
                continue
            # The one declared exception: verify-tag-shape's deriver step is
            # the per-step tag guard property 9 requires it to have INSTEAD of
            # a job-level `if:`, so it may carry a condition -- but only a
            # tag-ref test.
            if job == "verify-tag-shape" and is_tag_ref_test(step_if):
                continue
            violation(
                "gate-job-work-step-is-unconditional",
                "gate job '%s' has a step guarded by 'if: %s' that runs one of "
                "this repo's script/ci/ helpers. A gate job whose work step is "
                "skipped still concludes 'success', which is all any "
                "downstream needs/result check can see -- so this "
                "publishes with the gate never having run. Step: %s"
                % (job, step_if, step_label(step)),
            )
        # --- 10a. ... and neither may the publishing act itself -----------
        # The `script/ci/` marker above is what a GATE job's work looks like
        # in this repo. A PUBLISHING job's work is the push, and it is
        # recognisable on its own terms. Skipping it produces the state this
        # workflow's own header argues against -- a Release with no image
        # behind it -- while the job still reports success and the board
        # stays green.
        if job in published_names:
            for step in wf.steps(job):
                reason = publishing_step_reason(step)
                if reason is None:
                    continue
                step_if = wf.step_condition(step)
                if not step_if:
                    continue
                violation(
                    "publishing-step-is-unconditional",
                    "job '%s' has a step guarded by 'if: %s' that %s. A "
                    "publishing job whose push step is skipped still concludes "
                    "'success', so a tag cuts a Release with no image behind "
                    "it and nothing turns red. Step: %s"
                    % (job, step_if, reason, step_label(step)),
                )

        if work_steps == 0 and job in (TIER_B, "verify-tag-shape"):
            violation(
                "gate-job-work-step-is-unconditional",
                "gate job '%s' no longer runs any script/ci/ helper, so there "
                "is nothing left in it for this check -- or for the gate -- to "
                "be about" % job,
            )

    # --- 10c. the gate's work is THAT command, identified, not counted -----
    # See GATE_WORK_DRIVERS for the eight bypasses that walked past the count
    # above. Three clauses, all of them about ONE named invocation:
    #
    #   (a) it is PRESENT, spelled exactly as the table says;
    #   (b) it is UNCONDITIONAL (verify-tag-shape's deriver may carry the
    #       per-step tag guard property 9 requires it to have INSTEAD of a
    #       job-level `if:`, and nothing else);
    #   (c) NOTHING SHADOWS IT -- no other step in the job invokes the same
    #       script in any other spelling, so a second, guarded, `|| true`
    #       copy cannot be mistaken for the work while (a) is satisfied by a
    #       line that no longer runs anything.
    #
    # The one other spelling allowed by (c) is a `--print-<something>` QUERY,
    # which asks the driver for a value rather than doing the job (this
    # repo's Tier B job pulls the producer image the driver names). It must
    # itself be unconditional: a skipped query fails the step that uses it.
    for job in sorted(GATE_WORK_DRIVERS):
        if not wf.has(job):
            continue
        driver = GATE_WORK_DRIVERS[job]
        script = driver.split()[-1]

        # --- (d) nothing between the pinned string and what it DOES -------
        # `defaults.run` and `env:` reach this job's steps from above, so
        # refusing them only on the step leaves the two spellings that never
        # touch the step at all. Workflow level is included because it
        # reaches every job in the file, this one among them.
        for where, block in (
            ("this job's", wf.body(job).get("defaults")),
            ("the workflow's", wf.doc.get("defaults")),
        ):
            run_defaults = block.get("run") if isinstance(block, dict) else None
            if run_defaults:
                violation(
                    "gate-driver-runs-unmodified",
                    "%s defaults.run (%s) applies to gate job '%s', whose "
                    "work is pinned to \"%s\". `shell:` there is GitHub's "
                    "documented `command [...options] {0}` form -- `cat {0}` "
                    "PRINTS the driver and `bash -n {0}` syntax-checks it, "
                    "both exit 0, and the job reports 'success' with no "
                    "picture taken -- and `working-directory:` resolves the "
                    "same command against another tree. Neither shows up as "
                    "an edit to the step. Put the default on a job that runs "
                    "no pinned driver, or add the spelling to "
                    "GATE_WORK_STEP_MODIFIERS in check_release_gates.py "
                    "where it can be reviewed."
                    % (where, sorted(run_defaults), job, driver),
                )
        allowed_env = GATE_WORK_DRIVER_ENV.get(job, frozenset())
        for where, block in (
            ("job-level", wf.body(job).get("env")),
            ("workflow-level", wf.doc.get("env")),
        ):
            if isinstance(block, dict) and where == "job-level":
                block = {
                    name: value
                    for name, value in block.items()
                    if name not in allowed_env
                } or None
            if block:
                violation(
                    "gate-driver-runs-unmodified",
                    "a %s env: (%s) reaches gate job '%s', whose work is "
                    "pinned to \"%s\". The driver reads its own knobs from "
                    "the environment (TIER_B_PRODUCER_IMAGE, "
                    "TIER_B_VIEWER_IMAGE, TIER_B_BOOT_TIMEOUT), so a "
                    "variable set here decides WHAT the gate looks at while "
                    "the pinned line stays exactly as written. Declare it on "
                    "a job or a step that runs no pinned driver."
                    % (
                        where,
                        sorted(block) if isinstance(block, dict) else block,
                        job,
                        driver,
                    ),
                )

        # --- (e) the three keys that reach the driver without naming it ---
        # Round 8's `env:` refusals above cover the spellings that sit IN this
        # file's env blocks. These three do the same job from outside them:
        # `container:` gives every step a different filesystem (and its own
        # `env:`), `services:` rides alongside it, and a step writing to
        # $GITHUB_ENV or $GITHUB_PATH sets the driver's knobs -- or shadows
        # `bash` itself -- for every LATER step, naming nothing under
        # script/ci/ and so slipping past every path-based test here.
        #
        # Named, not enumerated: these are three keys we can point at, and the
        # evidence chain (see check_picture_leaves_evidence) is what covers
        # the ones nobody has thought of yet.
        for key in ("container", "services"):
            if wf.body(job).get(key) is not None:
                violation(
                    "gate-driver-runs-unmodified",
                    "gate job '%s' declares `%s:`, which decides what "
                    "`%s` even means -- a `container.image` whose bash is a "
                    "stub, or whose `env:` aims the driver at another "
                    "producer, leaves the pinned work step reporting "
                    "'success' with no picture taken. The gate runs on the "
                    "runner, unwrapped." % (job, key, driver),
                )

        for step in wf.steps(job):
            body = _strip_shell_comments(as_text(step.get("run") or ""))
            if step is not None and _CI_ENV_NAME_RE("GITHUB_OUTPUT").search(body):
                collapsed_run = " ".join(
                    normalise_paths(as_text(step.get("run") or "")).split()
                )
                if collapsed_run != driver:
                    violation(
                        "gate-driver-runs-unmodified",
                        "gate job '%s' has a step other than its pinned work "
                        "step writing to $GITHUB_OUTPUT. That file IS the "
                        "evidence channel -- a step that writes "
                        "`attestation=...` there hands the publisher a frame "
                        "nobody sampled, and every other check in this file "
                        "still passes. Only \"%s\" may write it. Step: %s"
                        % (job, driver, step_label(step)),
                    )

            if step is not None and _CD_INTO_CI_RE.search(
                normalise_paths(as_text(step.get("run") or ""))
            ):
                violation(
                    "gate-driver-runs-unmodified",
                    "gate job '%s' has a step that cd's into the driver's "
                    "directory. Every check here asks a question about a "
                    "PATH, and `cd script/ci` dissolves the question -- "
                    "`sed -i '1a exit 0' tier_b_visual_e2e.sh` afterwards "
                    "names nothing this file looks for. Work on the driver "
                    "from the repository root, or not at all. Step: %s"
                    % (job, step_label(step)),
                )

            for var in ("GITHUB_ENV", "GITHUB_PATH"):
                if _CI_ENV_NAME_RE(var).search(body):
                    violation(
                        "gate-driver-runs-unmodified",
                        "gate job '%s' has a step writing to $%s, which "
                        "reaches every later step in the job without naming "
                        "the driver: $GITHUB_ENV sets the knobs the driver "
                        "reads for itself, and $GITHUB_PATH can shadow `bash` "
                        "outright. Either way the pinned step runs and takes "
                        "no picture. Step: %s" % (job, var, step_label(step)),
                    )

        found_verbatim = False
        for step in wf.steps(job):
            run = as_text(step.get("run") or "")
            uses = as_text(step.get("uses") or "")
            ci_dir = script.rsplit("/", 1)[0] + "/"
            run_n = normalise_paths(run)
            uses_n = normalise_paths(uses)
            if (
                script not in run_n
                and script not in uses_n
                and ci_dir not in run_n
                and ci_dir not in uses_n
            ):
                continue
            collapsed = " ".join(run.split())
            step_if = wf.step_condition(step)

            # A step that invokes the driver AT ALL -- the pinned command or
            # a `--print-` query -- may not carry a key that changes what
            # that command does or where it does it.
            for key in GATE_WORK_STEP_MODIFIERS:
                if step.get(key) is None:
                    continue
                violation(
                    "gate-driver-runs-unmodified",
                    "gate job '%s' has a step that invokes %s and carries "
                    "'%s:'. The pinned command is compared as a STRING, and "
                    "this key decides what that string DOES: `shell: cat "
                    "{0}` prints the driver instead of running it (GitHub's "
                    "custom-shell form is `command [...options] {0}`), "
                    "`working-directory:` resolves it against another tree, "
                    "and `env:` sets the knobs the driver reads for itself. "
                    "In each case the step, and the job, report 'success' "
                    "with no picture taken. Step: %s"
                    % (job, script, key, step_label(step)),
                )

            if collapsed == driver:
                found_verbatim = True
                if step_if and not (
                    job == "verify-tag-shape" and is_tag_ref_test(step_if)
                ):
                    violation(
                        "gate-job-runs-its-driver-verbatim",
                        "gate job '%s' runs its driver (%s) behind 'if: %s'. A "
                        "gate job whose work step is skipped still concludes "
                        "'success', which is all any downstream needs/result "
                        "check can see, so this publishes with the gate never "
                        "having run. Step: %s"
                        % (job, driver, step_if, step_label(step)),
                    )
                continue
            # (c) EVERY invocation of the script in this step must itself be
            # a bare `--print-<x>` query. `"--print-" in run` was a substring
            # over the whole body, so `echo --print-nothing && <driver>
            # --help || true` was one unconditional step that satisfied it
            # while invoking the driver in a spelling that takes no picture.
            # Read the step's run body with comments stripped: a comment
            # that merely NAMES the driver was reported as an invocation,
            # which is the same conflation F1 exploited from the other side.
            occurrences = driver_occurrences(_strip_shell_comments(run), script)
            mutated = [detail for kind, detail in occurrences if kind == "mutation"]
            if mutated:
                violation(
                    "gate-job-runs-its-driver-verbatim",
                    "gate job '%s' has a step that does something TO its "
                    "driver (%s) rather than running it: %s. Truncating, "
                    "rewriting or replacing the driver leaves the pinned work "
                    "step running a file that no longer takes a picture, "
                    "while the job still reports 'success'. Step: %s"
                    % (job, script, "; ".join(mutated), step_label(step)),
                )
                continue
            invocations = [detail for kind, detail in occurrences if kind == "invocation"]
            # Nothing invoked and nothing mutated: the step only MENTIONS a
            # path under script/ci/ through a read-only command (see
            # _READ_ONLY_COMMANDS). Falling through to the catch-all below
            # reported `shellcheck <driver>` and `ls script/ci/` as bypasses,
            # which is the same read-a-mention-as-an-action conflation this
            # round set out to remove.
            if not occurrences and script not in uses:
                continue
            if (
                invocations
                and all(is_print_query(args) for args in invocations)
                and not step_if
            ):
                continue
            violation(
                "gate-job-runs-its-driver-verbatim",
                "gate job '%s' has a step that invokes %s in a spelling that "
                "is neither the gate's work nor an unconditional "
                "'--print-<x>' query: %s. `|| true`, `--help`, `--version`, a "
                "`set +e; ...; exit 0` wrapper and a second guarded copy all "
                "leave the job reporting 'success' with no picture taken. The "
                "job's work must be exactly \"%s\" -- if it legitimately needs "
                "an argument, add the new spelling to GATE_WORK_DRIVERS in "
                "check_release_gates.py, where it can be reviewed. Step: %s"
                % (job, script, collapsed or uses, driver, step_label(step)),
            )
        if not found_verbatim:
            violation(
                "gate-job-runs-its-driver-verbatim",
                "gate job '%s' has no step whose run: is exactly \"%s\". That "
                "command IS this job's work; a job that runs but does not do "
                "it reports 'success' all the same, and every needs/result "
                "check downstream sees a picture that was never taken. "
                "Counting steps that merely name something under script/ci/ "
                "is what this replaces: an unconditional decoy satisfied the "
                "count while the real work moved behind an 'if:'."
                % (job, driver),
            )

    # --- 6c. the report-only jobs still exist, and can still observe ------
    # Property 6 says nothing may DEPEND on these two. It said nothing about
    # them being there at all, so deleting both was a silent no-op -- and
    # silence is the entire failure they were added to fix.
    for job in REPORT_ONLY_JOBS:
        if not wf.has(job):
            violation(
                "report-only-jobs-still-exist",
                "report-only job '%s' is gone. Nothing depends on it -- that "
                "is the point -- so deleting it breaks no other check and "
                "reverses nothing visibly, while restoring the silence it "
                "exists to end: a release blocked by a cancelled or "
                "skipped picture gate becomes a grey job on a "
                "green-looking run" % job,
            )
            continue
        report_if = wf.condition(job)
        # STRUCTURAL, not a substring. This was the last `contains_word` in
        # the file, and a trailing comment satisfied it while the condition it
        # was reading had been replaced by `false`.
        terms = top_terms(report_if, "&")
        observes = any(
            canon_key(term) in TIER_B_NOT_SUCCESS_TESTS for term in terms
        )
        reads_failed_need = "always" in status_functions_in(report_if)
        if (
            not wf.needs_job(job, TIER_B)
            or not reads_failed_need
            or not observes
            or has_top_level_or(report_if)
        ):
            violation(
                "report-only-jobs-still-exist",
                "report-only job '%s' can no longer observe a picture gate "
                "that did not succeed. It must need %s, and its condition must "
                "carry always() (which is what lets a job read a need that did "
                "not succeed) and, as a mandatory top-level conjunct, "
                "\"needs.%s.result != 'success'\" (which is what makes it fire "
                "for skipped, cancelled and failure alike). needs: %s if: %s"
                % (
                    job,
                    TIER_B,
                    TIER_B,
                    wf.needs(job) or "<absent>",
                    report_if or "<absent>",
                ),
            )

    # --- 10b. the picture gate runs where a picture can be taken ----------
    # `runs-on: [self-hosted, gpu]` is not a performance choice. The job is
    # "boot a real Kit producer and assert a browser renders a non-black frame
    # from it", and no hosted runner has NVENC -- so `runs-on: ubuntu-latest`
    # here does not slow the gate down, it removes it.
    variants, problem = runs_on_variants(wf, TIER_B)
    if problem is not None:
        violation(
            "tier-b-runs-on-the-gpu-runner",
            "%s must run on [self-hosted, gpu], and this file cannot tell "
            "that it does: %s. It boots a real Kit producer and asserts a "
            "real browser renders a real frame, and no hosted runner has "
            "NVENC -- moving it off the GPU does not slow the gate down, it "
            "removes it." % (TIER_B, problem),
        )
    else:
        for variant in variants:
            labels = [label.strip() for label in variant]
            # CASE-INSENSITIVE, like canon_key and for the same reason.
            # GitHub matches runner labels case-insensitively; this compared
            # them case-SENSITIVELY while comparing expressions
            # case-insensitively, which is the exact inconsistency the
            # expression change argued against one round earlier.
            # `[Self-Hosted, GPU]` is the same runner and was reported as a
            # gate that had left the GPU. It failed CLOSED, so this is noise
            # rather than a hole -- and noise is how a check gets switched
            # off. The label still has to BE there, in some case.
            folded = [label.lower() for label in labels]
            if "self-hosted" in folded and "gpu" in folded:
                continue
            violation(
                "tier-b-runs-on-the-gpu-runner",
                "%s must run on [self-hosted, gpu]: it boots a real Kit "
                "producer and asserts a real browser renders a real frame, "
                "and no hosted runner has NVENC. Moving it off the GPU does "
                "not slow the gate down, it removes it. runs-on resolves to: "
                "%s" % (TIER_B, labels or "<empty>"),
            )

    # --- 11. EVERY job that can publish stands behind the picture gate ----
    # Properties 1-4 name call-release and publish-image because those were
    # the two jobs that published anything when they were written. That is an
    # allowlist, and an allowlist cannot see a new entry.
    if not published:
        violation(
            "publishing-jobs-are-identifiable",
            "no job in %s carries any evidence of publishing (a write "
            "permission scope, a registry login, a pushing build, a Release "
            "action, a publishing command). Either the publish path was "
            "removed, or it is now spelled in a way this checker cannot see -- "
            "and a gate that cannot find the thing it gates reports an "
            "invariant that protects nothing" % wf.path,
        )

    for job, reason in published:
        # The gate cannot be required to stand behind itself.
        if job == TIER_B:
            continue
        if not wf.needs_job(job, TIER_B):
            violation(
                "publishing-job-is-behind-the-picture-gate",
                "job '%s' can publish (%s) but does not have %s as an item of "
                "its needs, so it can publish for a commit whose picture was "
                "never verified. needs: %s"
                % (job, reason, TIER_B, wf.needs(job) or "<absent>"),
            )
            continue
        # Behind the gate by ONE OF THE TWO MECHANISMS this workflow uses.
        # They are not interchangeable and each is only safe on its own terms:
        #   A. no status function, so GitHub's default skip propagation
        #      applies -- that default is what makes an unavailable GPU runner
        #      block the release. This is call-release.
        #   B. a status function, PLUS an explicit mandatory top-level
        #      conjunct requiring the gate to have succeeded, and no top-level
        #      `||` for that conjunct to be an alternative of. This is
        #      publish-image, whose `!cancelled()` it needs because
        #      call-release is legitimately skipped on both dispatch paths.
        job_if = wf.condition(job)
        if status_functions_in(job_if) and not (
            has_tier_b_success_conjunct(job_if) and not has_top_level_or(job_if)
        ):
            violation(
                "publishing-job-is-behind-the-picture-gate",
                "job '%s' can publish (%s) and its condition carries a status "
                "function, which overrides GitHub's default skip propagation "
                "-- so a SKIPPED picture gate no longer stops it. A job in "
                "that position must ALSO require the gate explicitly, as a "
                "mandatory top-level conjunct \"needs.%s.result == 'success'\" "
                "with no top-level '||' in the condition. if: %s"
                % (job, reason, TIER_B, job_if or "<absent>"),
            )

    # Last, and deliberately last: the one property that is not about text.
    check_picture_leaves_evidence(wf)

    # ...and the one that inverts the question the other properties ask.
    check_gate_steps_are_declared(wf)


# The one property on this page that is not a question about text.
#
# Everything else here asks "does main.yaml say the right thing?". Review
# round 8 established the ceiling on that question: five single-step edits --
# `: > script/ci/tier_b_visual_e2e.sh --print-x` (truncate the driver, with a
# trailing token that this file's own --print- whitelist waves through),
# `sed -i '1a exit 0' script/ci/*.sh` (the glob is not the pinned path), a
# $GITHUB_PATH entry shadowing `bash`, a job-level `container:` whose bash is
# a stub, and `echo TIER_B_PRODUCER_IMAGE=busybox >> "$GITHUB_ENV"` -- each
# leave a workflow this checker passes and a Tier B job that goes green having
# sampled no frame. They are five members of an unbounded family: the checker
# reads a fixed set of keys, and a runner has endless ways to change what a
# command does. PUBLISH_RUN_RE's comment already concedes enumerations do not
# converge; round 8 showed that is just as true on the gate-work side.
#
# So this property does not enumerate. It requires the workflow to carry a
# chain that makes the frame ITSELF the thing publish-image waits on:
#
#   the acceptance spec samples a frame and writes an attestation
#     -> the driver verifies it against this run's commit, emits it as a
#        step output
#       -> the Tier B job exposes that step output as a job output
#         -> publish-image binds that job output and FAILS ON EMPTY
#
# All five bypasses break the same link -- no frame means no attestation means
# an empty output -- without this checker having to know they exist. What is
# enumerated here is only the chain's own four links, and those are ours: they
# change when we change them, not when an attacker finds a new spelling.
#
# This does NOT make the workflow unforgeable. Someone editing main.yaml can
# also edit these four lines, and this checker only guards what reaches `main`
# (a tag push runs the tagged commit's workflow -- see WHAT THIS CANNOT SEE,
# item 13). It raises the floor from "the job said it was fine" to "a frame
# exists, and it is this commit's frame", which is where the actual v0.3.0-rc1
# failure lived.
ATTESTATION_OUTPUT = "attestation"
ACCEPTANCE_STEP_ID = "acceptance"
ACCEPTANCE_EXPR = "steps.%s.outputs.%s" % (ACCEPTANCE_STEP_ID, ATTESTATION_OUTPUT)
ATTESTATION_REF = "needs.%s.outputs.%s" % (TIER_B, ATTESTATION_OUTPUT)
EVIDENCE_JOB = "require-picture-evidence"


def check_picture_leaves_evidence(wf):
    """Require the frame -> attestation -> job output -> publisher chain."""
    vid = "picture-leaves-evidence"

    if not wf.has(TIER_B):
        # Its absence is already a violation elsewhere; do not double-report.
        return

    # Link 3: the job exposes the evidence, sourced from the step that does
    # the gate work. A job output wired to some other step would be evidence
    # of nothing in particular.
    outputs = wf.body(TIER_B).get("outputs")
    attested = ""
    if isinstance(outputs, dict):
        attested = str(outputs.get(ATTESTATION_OUTPUT, "") or "")
    if not attested:
        violation(
            vid,
            "job '%s' does not declare an '%s' output, so the frame it "
            "sampled cannot leave the job and no later job can require it. "
            "A green job status is not a picture: it is equally green when "
            "the driver was replaced, shadowed or pointed at another image."
            % (TIER_B, ATTESTATION_OUTPUT),
        )
    elif " ".join(attested.split()) != "${{ %s }}" % ACCEPTANCE_EXPR:
        # An id MENTIONED is not an output READ. `"acceptance-ok"` and
        # `${{ steps.acceptance.outcome }}` both contain the id and are both
        # permanently non-empty -- a constant dressed as evidence.
        violation(
            vid,
            "job '%s' declares its '%s' output as %r, which is not %s. The "
            "evidence must be the value the gate-work step produced; a "
            "constant, or that step's `outcome`, is never empty and so "
            "attests to nothing."
            % (
                TIER_B,
                ATTESTATION_OUTPUT,
                attested,
                "${{ %s }}" % ACCEPTANCE_EXPR,
            ),
        )

    # Link 2b: that step still carries the id the output reads from.
    if not any(
        str(step.get("id", "")) == ACCEPTANCE_STEP_ID
        for step in wf.steps(TIER_B)
        if isinstance(step, dict)
    ):
        violation(
            vid,
            "no step in '%s' has id '%s', so the job output above resolves to "
            "the empty string -- and an empty attestation is exactly what a "
            "job that sampled no frame produces. The two must not look alike."
            % (TIER_B, ACCEPTANCE_STEP_ID),
        )

    # Link 4: one job REQUIRES the evidence, in a way that can actually fail.
    # A guard that reads the value and shrugs is decoration.
    if not wf.has(EVIDENCE_JOB):
        violation(
            vid,
            "there is no '%s' job, so nothing turns the frame into something a "
            "publisher can wait on. Without it the release path rests on the "
            "Tier B job's STATUS, which stays green when the driver is "
            "replaced, shadowed, or pointed at another image."
            % EVIDENCE_JOB,
        )
    else:
        # The binding must be the attestation itself, ALONE. A value that
        # merely contains the reference -- `${{ ... }}.`, `${{ ... }}${{
        # github.sha }}` -- is never empty, so the gate can never fire, and
        # round 10 got past the previous "does it contain the ref?" test with
        # exactly one extra character. Whether the job then FAILS on empty is
        # not asked of shell text any more: its work is pinned in
        # GATE_WORK_DRIVERS, and require_attestation.sh is what decides.
        job_env = wf.body(EVIDENCE_JOB).get("env")
        bound = (
            [
                name
                for name, value in job_env.items()
                if " ".join(str(value).split()) == "${{ %s }}" % ATTESTATION_REF
            ]
            if isinstance(job_env, dict)
            else []
        )
        if not bound:
            violation(
                vid,
                "job '%s' does not bind %s, alone, to an environment variable, "
                "so it gates on nothing -- or on a value that is never empty."
                % (EVIDENCE_JOB, "${{ %s }}" % ATTESTATION_REF),
            )
        # Its own condition must not override skip propagation: a status
        # function here would let it run -- and pass -- after a skipped or
        # failed Tier B, which is the whole failure it exists to stop.
        gate_if = wf.condition(EVIDENCE_JOB)
        if status_functions_in(gate_if):
            violation(
                vid,
                "job '%s' carries a status function in its condition (%s), "
                "which overrides GitHub's default skip propagation -- so it "
                "would run, and could pass, for a Tier B that never ran."
                % (EVIDENCE_JOB, gate_if),
            )

    # ...and every publisher stands behind it, by the same two mechanisms the
    # picture gate itself is required to be behind.
    for job, reason in publishing_jobs(wf):
        if job in (TIER_B, EVIDENCE_JOB):
            continue
        if not wf.needs_job(job, EVIDENCE_JOB):
            violation(
                vid,
                "job '%s' can publish (%s) but does not have %s in its needs, "
                "so it can publish for a commit whose frame was never "
                "recorded. needs: %s"
                % (job, reason, EVIDENCE_JOB, wf.needs(job) or "<absent>"),
            )
            continue
        job_if = wf.condition(job)
        if status_functions_in(job_if) and not (
            ("needs.%s.result == 'success'" % EVIDENCE_JOB) in (job_if or "")
            and not has_top_level_or(job_if)
        ):
            violation(
                vid,
                "job '%s' can publish (%s) and its condition carries a status "
                "function, so a SKIPPED evidence gate no longer stops it. It "
                "must ALSO require \"needs.%s.result == 'success'\" as a "
                "mandatory top-level conjunct. if: %s"
                % (job, reason, EVIDENCE_JOB, job_if or "<absent>"),
            )


def yaml_dump_job(wf, job):
    """Flatten a job back to text, for presence questions about expressions.

    Expressions like ${{ needs.x.outputs.y }} can appear in `env:`, `with:`,
    `if:` or inline in a `run:`; asking "does this job mention it at all" is a
    presence question, and flattening is the honest way to ask it. The
    FAILS-ON-EMPTY question below is structural and is not asked this way.
    """
    return yaml.safe_dump(wf.body(job), default_flow_style=False, sort_keys=True)


_EXIT_NONZERO_RE = re.compile(r"(?:^|[;&|\n(]|\bthen\b|\belse\b)\s*exit\s+[1-9]")


def _strip_quoted(text):
    """Blank out single- and double-quoted spans, keeping newlines."""
    out = []
    quote = None
    for char in text:
        if quote is None and char in "\"'":
            quote = char
            out.append(" ")
        elif quote is not None and char == quote:
            quote = None
            out.append(" ")
        elif quote is not None:
            out.append("\n" if char == "\n" else " ")
        else:
            out.append(char)
    return "".join(out)


def _refuses_empty_attestation(wf, job):
    """True when some step binds the attestation and exits non-zero on empty.

    Deliberately narrow: the step must bind the value into the environment
    (so the shell sees a value, not an interpolation the runner splices in)
    and its body must contain both an emptiness test and a non-zero exit. A
    guard spelled some other way reads as absent and fails closed, which is
    the correct direction for a gate -- a false alarm costs a comment, a
    missed one costs a release nobody looked at.
    """
    job_env = wf.body(job).get("env")
    job_bound = (
        [
            name
            for name, value in job_env.items()
            if ATTESTATION_REF in str(value)
        ]
        if isinstance(job_env, dict)
        else []
    )

    for step in wf.steps(job):
        if not isinstance(step, dict):
            continue
        # Bound at either level: a job-level `env:` reaches every step, and
        # binding it once for a single-step job is the clearer spelling.
        env = step.get("env")
        bound = list(job_bound)
        if isinstance(env, dict):
            # A step-level `env:` REBINDING a job-level name wins at runtime.
            # Counting the union meant `env: {ATTESTATION: sentinel}` on the
            # guard step left the checker satisfied by the job-level binding
            # while the shell saw the constant -- `-z` never true, the guard
            # unable to fire. A shadowed name is not bound.
            shadowed = {
                name
                for name, value in env.items()
                if ATTESTATION_REF not in str(value)
            }
            bound = [name for name in bound if name not in shadowed]
            bound += [
                name
                for name, value in env.items()
                if ATTESTATION_REF in str(value)
            ]
        if not bound:
            continue
        body = _strip_shell_comments(str(step.get("run", "")))
        if not body:
            continue
        tests_empty = any(
            ('-z "${%s}"' % name) in body
            or ('-z "$%s"' % name) in body
            or ('-n "${%s}"' % name) in body
            or ('-n "$%s"' % name) in body
            for name in bound
        )
        # `exit 1` must be a COMMAND, not a mention. Searching the raw
        # body accepted `echo "a stricter policy would exit 1 here"` --
        # a guard that prints and returns 0, which the docstring above
        # claimed was impossible. Quoted spans are blanked before the
        # search; the emptiness test is asked of the unstripped body,
        # because `-z "${VAR}"` is quoted by construction.
        if tests_empty and _EXIT_NONZERO_RE.search(_strip_quoted(body)):
            return True
    return False


# ===========================================================================
# THE ALLOW-LIST. Eleven rounds of the other thing.
# ===========================================================================
#
# Every property above this asks "does this step name something forbidden?"
# -- a question over an unbounded space, and the record is unambiguous. Each
# round closed the spellings the last reviewer typed; each next reviewer
# found another in under an hour: `script/ci//`, then `script//ci/` and
# `script/./ci/`, then `cd script/ci`, then `${GITHUB_PATH:?}` and four more
# expansions, and finally
#
#     find . -name 'tier_b_visual_e2e.sh' -exec sed -i '2i exit 0' {} +
#
# which names neither the directory every path test keys on nor any variable
# the name tests match. That one was executed against the real drivers: both
# exited 0, the evidence gate printed "picture verified", and the checker
# printed "holds the release invariant". A blocklist over shell does not
# converge, and this file spent eleven rounds demonstrating it.
#
# So the question is inverted. A gate job's steps are ENUMERATED HERE. Not
# "is this step forbidden?" but "is this step one of the ones we declared?".
# The space is finite, it is ours, and it changes only when we change it --
# an unknown step is refused whatever it does and whatever it names, so the
# next spelling nobody has thought of is refused too.
#
# The cost is real and is the point: adding a step to a gate job means adding
# a line here, in a diff a reviewer sees. These jobs decide whether a version
# can be published. They are not a place for convenience steps.
#
# Matching is EXACT, on the step's ACTION (`uses:`, including its @ref) or its
# collapsed, path-normalised `run:` body.
#
# There is no wildcard. There was, for one commit -- a `" *"` suffix meaning
# "starts with this" -- and it let
#
#     ./script/setup.sh apply && find . -name 'tier_b_visual_e2e.sh' \
#       -exec sed -i '2i exit 0' {} +
#
# through, because a prefix match cannot tell an ARGUMENT from a chained
# COMMAND. That is the allow-list making the blocklist's mistake: a pattern
# that is open at one end is open to everything past that end. Every entry is
# the whole step or it is not an entry.
#
# The @ref is part of the action, not decoration. Matching `actions/checkout`
# without it would let a declared step be pointed at `@main`, or at a fork,
# which is the supply-chain half of the same hole.
GATE_JOB_ALLOWED_STEPS = {
    "tier-b-visual-e2e": (
        "uses:actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803",
        "uses:actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
        "run:docker run --rm -v \"${GITHUB_WORKSPACE}\":/w -w /w "
        "busybox@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d"
        "11b1ab28616 sh -c ' rm -rf .tier-b-artifacts 2>/dev/null true'",
        "run:./script/setup.sh apply sed -i "
        "\"s|^WS_PATH=.*|WS_PATH=${GITHUB_WORKSPACE}|\" .env.generated",
        "run:./script/build.sh -t e2e-test",
        "run:docker pull \"$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)\"",
        "run:bash script/ci/tier_b_visual_e2e.sh",
    ),
    "verify-tag-shape": (
        "uses:actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803",
        "run:bash script/ci/derive_image_tag.sh",
    ),
    "require-picture-evidence": (
        "uses:actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803",
        "run:bash script/ci/require_attestation.sh",
    ),
}


def step_signature(step):
    """What this step IS, for allow-list comparison."""
    uses = as_text(step.get("uses") or "")
    if uses:
        # The @ref included: a declared action pointed at @main, or at a fork,
        # is a different action with the same name.
        return "uses:" + normalise_paths(uses.strip())
    return "run:" + " ".join(normalise_paths(as_text(step.get("run") or "")).split())


def step_is_allowed(signature, allowed):
    return signature in allowed


def check_gate_steps_are_declared(wf):
    """No step runs in a gate job unless it is declared above.

    And no UNDECLARED JOB runs on the self-hosted runner at all. That runner
    is persistent and shared: jobs landing on it see the same machine and the
    same workspace directory, so a job nobody declared can prepare the ground
    for the one that takes the picture -- plant a shim, edit the checked-out
    driver -- without ever appearing in the gate job whose steps this table
    constrains. The allow-list would otherwise stop at the job boundary, which
    is not where the trust boundary is.
    """
    for job in wf.names():
        if job in GATE_JOB_ALLOWED_STEPS:
            continue
        if any(
            "self-hosted" in str(variant)
            for variant in runs_on_variants(wf, job)
        ):
            violation(
                "gate-job-runs-only-declared-steps",
                "job '%s' asks for the self-hosted runner but is not declared "
                "in GATE_JOB_ALLOWED_STEPS. That runner is persistent and "
                "shared -- an undeclared job on it can edit the workspace or "
                "the PATH that the picture gate then runs in, while the gate "
                "job's own steps stay exactly as declared. Declare the job, or "
                "run it on a hosted runner." % job,
            )

    for job, allowed in sorted(GATE_JOB_ALLOWED_STEPS.items()):
        if not wf.has(job):
            continue
        for step in wf.steps(job):
            if not isinstance(step, dict):
                continue
            signature = step_signature(step)
            if step_is_allowed(signature, allowed):
                continue
            violation(
                "gate-job-runs-only-declared-steps",
                "gate job '%s' has a step that is not declared in "
                "GATE_JOB_ALLOWED_STEPS: %s. A gate job may run arbitrary "
                "commands BEFORE its pinned step, and the pinned script is an "
                "ordinary file in that job's own workspace -- so one undeclared "
                "step can rewrite the driver, the evidence gate, or both, "
                "while every pinned line stays byte-identical. If this step is "
                "legitimate, declare it there, where a reviewer sees it."
                % (job, signature[:200]),
            )


def main(argv):
    path = argv[1] if len(argv) > 1 else ".github/workflows/main.yaml"
    wf = Workflow(path)
    check(wf)
    if _violations:
        sys.stderr.write(
            "check_release_gates: %d violation(s) in %s\n"
            % (len(_violations), path)
        )
        return 1
    sys.stdout.write(
        "check_release_gates: %s holds the release invariant\n" % path
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except SystemExit:
        raise
    # Deliberately BaseException, not Exception. NEVER a silent exit: the
    # implementation this replaced could die with status 141 and no output at
    # all, from a SIGPIPE between two of its own awk helpers, on an input a
    # reviewer supplied -- and a checker that says nothing and exits non-zero
    # teaches a maintainer to re-run it until it is quiet, which is a gate
    # with a retry button. Anything unexpected here is a traceback on stderr
    # and exit 2, the same status as "unreadable".
    except BaseException:
        traceback.print_exc()
        sys.stderr.write(
            "check_release_gates: internal error; the release invariant was "
            "NOT verified\n"
        )
        raise SystemExit(2)
