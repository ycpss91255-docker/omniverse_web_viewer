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

 1. ONE FILE. A gate moved into a reusable workflow, a composite action, or
    a second workflow file is not examined. A `uses:` line naming one is read
    only for the publishing signals in PUBLISH_USES / PUBLISH_RUN_RE.
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
    spelling, and a publishing command nobody has thought of yet is still not
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
    set. Whether the machine answering to `gpu` actually has an NVENC-capable
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
12. THIS FILE'S OWN LINT. `shellcheck /ci/*.sh` cannot see a `.py`. The
    `devel-test` stage now runs pyflakes over `/ci/*.py`, which catches
    undefined names and unused imports and NOTHING about whether a property
    is right; release_gate_workflow.bats, which proves each property fails
    when removed, is still the only thing that does that.
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
    TIER_B: "bash script/ci/tier_b_visual_e2e.sh",
    "verify-tag-shape": "bash script/ci/derive_image_tag.sh",
}

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
    re.compile(r"\b(?:oras|crane|regctl)\s+(?:push|copy)\b"),
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
        # violation with a fix (take it off `push:`, or split the tag trigger
        # into its own `on.push` entry) rather than a guess.
        for key in tag_trigger_path_filters(wf):
            violation(
                "tag-trigger-has-no-path-filter",
                "on.push carries a '%s:' filter alongside 'tags:'. A path "
                "filter that matches nothing stops a tag push from starting "
                "this workflow at all, and this checker cannot evaluate it "
                "against a commit it does not have -- so the tag patterns "
                "below can all match while nothing runs. Remove it from the "
                "push trigger." % key,
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
        found_verbatim = False
        for step in wf.steps(job):
            run = as_text(step.get("run") or "")
            uses = as_text(step.get("uses") or "")
            if script not in run and script not in uses:
                continue
            collapsed = " ".join(run.split())
            step_if = wf.step_condition(step)
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
            if "--print-" in run and not step_if:
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
            if "self-hosted" in labels and "gpu" in labels:
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
