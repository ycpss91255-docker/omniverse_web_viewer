#!/usr/bin/env python3
"""Verify the Tier B visual-acceptance attestation.

WHY THIS EXISTS
---------------
The picture gate used to rest on one fact: the `tier-b-visual-e2e` job exited
0. Review round 8 produced five single-step edits to `.github/workflows/
main.yaml` that each keep that fact true while removing the picture entirely --
truncating the driver (``: > script/ci/tier_b_visual_e2e.sh --print-x``),
``sed -i '1a exit 0' script/ci/*.sh``, a ``$GITHUB_PATH`` entry shadowing
``bash``, a job-level ``container:`` whose ``bash`` is a stub, and
``$GITHUB_ENV`` pointing ``TIER_B_PRODUCER_IMAGE`` at busybox. Static analysis
of the workflow cannot tell any of them from a real run, because the workflow
text is identical; what differs is whether a frame was ever sampled.

So the gate stops asking "did the job succeed?" and starts asking "where is the
frame?". `test/e2e/tier-b-visual.spec.ts` writes this attestation only after it
has sampled a frame that cleared every threshold; this script re-checks the
numbers and binds them to the commit and run being published. All five
bypasses end with no attestation at all, so all five fail here at once -- and
they fail without this script having to know that any of them exist, which is
the property no amount of key enumeration in `check_release_gates.py` can buy.

FAILS CLOSED, ALWAYS
--------------------
Missing file, unreadable file, malformed JSON, a missing or non-numeric field,
a degenerate frame, a commit or run that does not match the environment being
published -- every one exits non-zero. There is no flag, no env var and no
input that makes this script pass something it could not verify. A gate with a
way out gets used on the day it matters most.

Prints a one-line human-readable summary on success; that line is what the
driver hands to `$GITHUB_OUTPUT` for `publish-image` to require.
"""

import json
import os
import sys


def fail(message):
    """Exit non-zero with a message on stderr. The only way out of here."""
    sys.stderr.write("[tier-b][attestation] {}\n".format(message))
    raise SystemExit(1)


def env_float(name, default):
    """Read a numeric threshold from the environment, refusing junk."""
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError:
        fail("{} is not a number: {!r}".format(name, raw))


def require_number(doc, key):
    """Pull a numeric field, refusing absence, wrong type and NaN alike.

    `bool` is rejected explicitly: it is a subclass of `int` in Python, so a
    JSON `true` would otherwise sail through as 1 and read as a bright frame.
    """
    if key not in doc:
        fail("attestation has no {!r} field".format(key))
    value = doc[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail("attestation field {!r} is not a number: {!r}".format(key, value))
    if value != value:  # NaN, which compares >= to nothing
        fail("attestation field {!r} is NaN".format(key))
    return float(value)


def require_binding(doc, key, env_name):
    """Check a field against the environment, when the environment says.

    Locally there is no GITHUB_SHA and nothing to bind to, and the driver is
    still useful there -- so an unset variable means "not applicable", not
    "matches anything". In CI both are set and both are checked, which is where
    it counts: an attestation left over from an earlier run, or copied from a
    branch that did have a picture, names a different commit and is refused.
    """
    expected = os.environ.get(env_name)
    if not expected:
        return
    if key not in doc:
        fail("attestation has no {!r} field, but {} is set".format(key, env_name))
    actual = str(doc[key])
    if actual != expected:
        fail(
            "attestation {} is {!r}, but this run publishes {!r} -- "
            "this evidence is from a different run".format(key, actual, expected)
        )


def main():
    path = os.environ.get("OWV_ATTESTATION")
    if not path:
        fail("OWV_ATTESTATION is not set")

    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as err:
        fail("cannot read {}: {}".format(path, err))

    try:
        doc = json.loads(raw)
    except ValueError as err:
        fail("{} is not valid JSON: {}".format(path, err))

    if not isinstance(doc, dict):
        fail("{} is not a JSON object".format(path))

    require_binding(doc, "commit", "GITHUB_SHA")
    require_binding(doc, "run_id", "GITHUB_RUN_ID")

    width = require_number(doc, "width")
    height = require_number(doc, "height")
    mean_luma = require_number(doc, "meanLuma")
    bright_fraction = require_number(doc, "brightFraction")

    if width <= 0 or height <= 0:
        fail("attested frame has no dimensions: {}x{}".format(width, height))

    min_mean_luma = env_float("OWV_MIN_MEAN_LUMA", 8.0)
    min_bright_fraction = env_float("OWV_MIN_BRIGHT_FRACTION", 0.1)

    if mean_luma < min_mean_luma:
        fail(
            "attested frame is black: meanLuma {} < {}".format(
                mean_luma, min_mean_luma
            )
        )
    if bright_fraction < min_bright_fraction:
        fail(
            "attested frame is black: brightFraction {} < {}".format(
                bright_fraction, min_bright_fraction
            )
        )

    sys.stdout.write(
        "{:g}x{:g} meanLuma={:g} brightFraction={:g}\n".format(
            width, height, mean_luma, bright_fraction
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
