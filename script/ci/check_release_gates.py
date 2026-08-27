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
    whitespace-insensitive) and compared against closed sets of spellings
    (TAG_REF_TESTS, TIER_B_SUCCESS_TESTS, NOT_CANCELLED_TESTS). An equivalent
    expression written some OTHER way is reported as a violation -- a false
    positive whose fix is to add the spelling to that set -- and an
    inequivalent one that happens to canonicalise to a set member is not
    caught. `contains()`, `format()`, `fromJSON()` and every other function
    are opaque text.
 3. Gate WORK is recognised as "a step whose `run:` or `uses:` names one of
    this repo's `script/ci/` helpers". A gate whose work is an inline `run:`
    block, a third-party action, or a helper invoked through a variable can
    still be given a step-level `if:` unseen. Shell comments are stripped
    from `run:` bodies by a "whitespace-preceded `#` to end of line"
    heuristic, so a `#` inside a quoted shell string is treated as a comment.
 4. PUBLISHING is recognised by effective `permissions:` (job-level, else
    workflow-level), by the action names in PUBLISH_USES, by a truthy or
    expression-valued `push:` input, and by the command patterns in
    PUBLISH_RUN_RE. A job that publishes some other way -- an unfamiliar
    action, a helper script that pushes without saying so, a token passed to
    a program this list does not name -- is not derived and is therefore not
    required to carry the gate. Widening those lists is the whole cost of
    closing this. One gap here is DELIBERATE and is a trade, not an
    oversight: `docker/build-push-action` is not a signal by itself, only its
    `push:` input is, because `push: false` is how this repo's own
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
    GPU is not knowable from here.
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
PUBLISH_RUN_RE = (
    re.compile(r"\bdocker\s+push\b"),
    re.compile(r"\bdocker\s+compose\s+push\b"),
    re.compile(
        r"\bdocker\s+(?:buildx\s+)?(?:build|bake)\b[^\n]*(?:\s|^)--push\b"
    ),
    re.compile(r"\bgh\s+release\s+(?:create|upload)\b"),
    re.compile(r"\bnpm\s+publish\b"),
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


TAG_REF_TESTS = frozenset(
    (
        "startsWith(github.ref,'refs/tags/')",
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
    return canon(term) in TAG_REF_TESTS


def is_tier_b_success_test(term):
    return canon(term) in TIER_B_SUCCESS_TESTS


def status_functions_in(expr):
    """Every status function called at expression level in <expr>.

    Outside string literals only, so a job name or a commit message
    containing the word `always` is not a status function -- and, equally, a
    status function cannot be hidden inside one.
    """
    plain = []
    for _, char, in_string in _scan(expr):
        plain.append(" " if in_string else char)
    text = "".join(plain)
    found = []
    for name in STATUS_FUNCTIONS:
        if re.search(r"\b%s\s*\(" % name, text):
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

    def runs_on(self, job):
        return as_list(self.body(job).get("runs-on"))

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
        run = _strip_shell_comments(as_text(step.get("run") or ""))
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
    run = _strip_shell_comments(as_text(step.get("run") or ""))
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


def tag_glob_matches(globs, tag):
    for glob in globs:
        try:
            if re.match(glob_to_regex(glob), tag):
                return True
        except re.error:
            continue
    return False


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
        if canon(term) in NOT_CANCELLED_TESTS
    ]
    wide = [
        term
        for term in top_terms(publish_if, "&")
        if canon(term) not in NOT_CANCELLED_TESTS and status_functions_in(term)
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
        # PRESENCE IS NOT REACHABILITY: `- 'never-matches-anything'` is a
        # sequence with items in it, and it starts no workflow for any real
        # tag. Both shapes this repo cuts are tried, because the incident
        # behind the rule (#70) was an rc.
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
            canon(term) in TIER_B_NOT_SUCCESS_TESTS for term in terms
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
    labels = [label.strip() for label in wf.runs_on(TIER_B)]
    if "self-hosted" not in labels or "gpu" not in labels:
        violation(
            "tier-b-runs-on-the-gpu-runner",
            "%s must run on [self-hosted, gpu]: it boots a real Kit producer "
            "and asserts a real browser renders a real frame, and no hosted "
            "runner has NVENC. Moving it off the GPU does not slow the gate "
            "down, it removes it. runs-on: %s" % (TIER_B, labels or "<absent>"),
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
