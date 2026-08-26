#!/usr/bin/env bash
#
# check_release_gates.sh [<workflow.yaml>]
#
# Assert the STRUCTURAL properties that make the release invariant true.
#
# The rule is absolute and predates this script: no version may publish
# without the Tier B picture gate having passed ON THAT COMMIT -- no override
# input, no `continue-on-error`, no `if: always()` escape, and an unavailable
# GPU runner BLOCKS the release rather than being waved through (#70, after
# v0.3.0-rc1 published with no picture ever verified for it).
#
# Until now that rule lived only in `if:` / `needs:` expressions and prose in
# .github/workflows/main.yaml, and NOTHING verified it. Every existing gate --
# bats, node, both e2e tiers, hadolint, shellcheck -- stays green while the
# protection is deleted, because none of them reads the workflow. One `||
# github.event_name == 'workflow_dispatch'` added while debugging, or one
# `tier-b-visual-e2e` dropped from a `needs:` list, and the next tag publishes
# blind with a full board of green checks. This script is the thing that turns
# red for that.
#
# It runs anywhere with bash + awk: no GPU, no tag push, no GitHub, no network,
# no YAML dependency (the test image has neither python3 nor yq -- see
# release_gate_workflow.bats, which is the caller on every PR).
#
# Every violation is printed with a stable [id]. release_gate_workflow.bats
# mutates the real workflow once per id and asserts THAT id is reported, so an
# assertion here that cannot fail is itself caught -- the failure mode this
# repo has been bitten by three times.
set -euo pipefail

WORKFLOW="${1:-.github/workflows/main.yaml}"

# The jobs on the publish path. A `continue-on-error` on any of these turns a
# gate into a suggestion, at job level or on any step inside one.
GATE_JOBS=(
  call-docker-build
  verify-tag-shape
  call-release
  publish-image
  tier-b-visual-e2e
)

# Report-only jobs. They exist to ADD a failure (a blocked release that would
# otherwise be a grey cancelled job on a green-looking run). Nothing may
# `needs:` one, because that would make a job whose whole design is to fail
# loudly into something a downstream job waits on -- and their `always()` would
# then propagate where the gate rule forbids a status function.
REPORT_ONLY_JOBS=(
  release-blocked-report
  nightly-tier-b-report
)

violations=0

# violation <id> <message>
violation() {
  printf 'check_release_gates: VIOLATION [%s] %s\n' "$1" "$2" >&2
  violations=$((violations + 1))
}

# The workflow with full-line comments, blank lines and trailing whitespace
# removed. Comment stripping is LOAD-BEARING, not tidiness: this file argues
# for its own gates in prose, so it contains the literal strings
# `continue-on-error` and `if: always()` inside comment blocks that say those
# things are forbidden. A grep over the raw file would report the argument as
# the violation. Only whole-line comments are dropped, so a `#` inside a value
# (an image digest, a version pin) is left alone.
normalize() {
  awk '
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line ~ /^[[:space:]]*#/ { next }
    line ~ /^[[:space:]]*$/ { next }
    { print line }
  ' "${WORKFLOW}"
}

# job_body <job>: the lines belonging to <job>, its header excluded. Job names
# are the only 2-space keys under `jobs:`; a column-0 key ends the section.
job_body() {
  normalize | awk -v job="$1" '
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    inj && /^[^[:space:]]/ { inj = 0 }
    !inj { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      cur = $0; sub(/^  /, "", cur); sub(/:.*$/, "", cur); next
    }
    cur == job { print }
  '
}

# list_jobs: every job name, in file order.
list_jobs() {
  normalize | awk '
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    inj && /^[^[:space:]]/ { inj = 0 }
    !inj { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      j = $0; sub(/^  /, "", j); sub(/:.*$/, "", j); print j
    }
  '
}

# job_key <job> <key>: the JOB-LEVEL value of <key>, folded onto one line.
#
# Job-level means exactly 4 spaces of indent, which is what separates a job's
# own `if:` from a step's -- verify-tag-shape has the second and must never
# have the first. A `>-` folded scalar's continuation lines (6+ spaces) are
# joined with single spaces and the block marker is dropped, so the caller
# sees the expression GitHub would evaluate. Empty output means absent.
job_key() {
  job_body "$1" | awk -v key="$2" '
    !found && $0 ~ ("^    " key ":") {
      v = $0
      sub(/^    [^:]*:[[:space:]]*/, "", v)
      acc = v; found = 1; next
    }
    found {
      if ($0 ~ /^      /) {
        l = $0; sub(/^[[:space:]]+/, "", l); acc = acc " " l; next
      }
      exit
    }
    END {
      if (found) { sub(/^[|>][-+]?[[:space:]]*/, "", acc); print acc }
    }
  '
}

# top_terms <op-char>: split the expression on stdin at every doubled
# <op-char> (`||` or `&&`) that sits at parenthesis depth 0, one term per
# line, trimmed. Depth is what makes this structural rather than a grep: the
# `||` inside `(inputs.run_tier_b || inputs.publish_image_tag != '')` is a
# nested alternative, not a top-level one, and must not be split out.
top_terms() {
  awk -v op="$1" '
    {
      depth = 0; cur = ""; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "(") depth++
        else if (c == ")") depth--
        if (depth == 0 && c == op && substr($0, i + 1, 1) == op) {
          print cur; cur = ""; i++
          continue
        }
        cur = cur c
      }
      print cur
    }
  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# tag_trigger_globs: the `on.push.tags` sequence items.
tag_trigger_globs() {
  normalize | awk '
    /^on:[[:space:]]*$/ { ino = 1; next }
    ino && /^[^[:space:]]/ { ino = 0 }
    !ino { next }
    /^    tags:[[:space:]]*$/ { intags = 1; next }
    intags && /^      - / { print; next }
    intags && !/^      / { intags = 0 }
  '
}

# contains_word <needle> <haystack>: substring test, kept as one named idea so
# the checks below read as assertions rather than as bracket soup.
#
# SUBSTRING IS NOT A STRUCTURAL TEST, and the checks below use this only where
# a substring is genuinely the property (a `continue-on-error` anywhere in a
# job body, a status function anywhere in a condition -- both are "this token
# must not appear"). Where the property is "this term must be REQUIRED", a
# substring is a bypass: `(X || Y)` still contains X. Those checks split the
# expression instead; see is_tier_b_success_test and top_terms.
contains_word() {
  case "$2" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_tier_b_success_test <term>: true when <term>, one top-level conjunct of a
# condition, IS the tier-b success requirement rather than merely containing
# it. A closed SET of spellings rather than one literal, so an equivalent
# rewrite is not reported as a bypass; the violation message names the set, so
# a maintainer who wants a sixth spelling knows what to add here.
is_tier_b_success_test() {
  case "$1" in
    "needs.tier-b-visual-e2e.result == 'success'") return 0 ;;
    "(needs.tier-b-visual-e2e.result == 'success')") return 0 ;;
    "'success' == needs.tier-b-visual-e2e.result") return 0 ;;
    "('success' == needs.tier-b-visual-e2e.result)") return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -r "${WORKFLOW}" ]; then
  printf 'check_release_gates: cannot read workflow %s\n' "${WORKFLOW}" >&2
  exit 2
fi

# A workflow with no jobs would pass every check below vacuously, which is the
# same class of hole this script exists to close. Refuse it outright.
if [ -z "$(list_jobs)" ]; then
  printf 'check_release_gates: %s declares no jobs\n' "${WORKFLOW}" >&2
  exit 2
fi

publish_needs="$(job_key publish-image needs)"
publish_if="$(job_key publish-image if)"
release_needs="$(job_key call-release needs)"
release_if="$(job_key call-release if)"
tier_b_if="$(job_key tier-b-visual-e2e if)"

# --- 1. the publish is wired to the picture gate --------------------------
if ! contains_word 'tier-b-visual-e2e' "${publish_needs}"; then
  violation publish-image-needs-tier-b \
    "publish-image does not need tier-b-visual-e2e, so an image can be pushed for a commit whose picture was never verified. needs: ${publish_needs:-<absent>}"
fi

# --- 2. ... and requires it to have SUCCEEDED, not merely not-failed ------
# skipped / cancelled / failure must all block. `!cancelled()` in this job's
# condition means a skipped need does not skip it, so the explicit result
# check is the only thing left holding the line.
#
# STRUCTURAL, NOT A SUBSTRING. This check used to be `contains_word`, which is
# exactly the threat this file's own header names -- and two one-line edits
# walked straight through it while every test stayed green:
#
#   (needs.tier-b-visual-e2e.result == 'success' || inputs.publish_image_tag != '')
#     the required string is still present, but it is now an ALTERNATIVE: a
#     hand-typed publish_image_tag satisfies the condition with the gate
#     skipped, failed or never run.
#
#   ... && (...) || inputs.publish_image_tag != ''
#     one `||` appended at the END of the whole condition. `&&` binds tighter
#     than `||`, so the entire gate chain becomes one alternative of a
#     disjunction and the other alternative publishes on its own.
#
# So both halves are asserted, the same shape property 8 already applies to
# tier-b's own condition: the requirement must be a MANDATORY TOP-LEVEL
# CONJUNCT, and the condition must have no top-level `||` for it to be an
# alternative of.
if [ "$(printf '%s\n' "${publish_if}" | top_terms '|' | wc -l)" -ne 1 ]; then
  violation publish-image-gate-is-not-optional \
    "publish-image's condition has a top-level '||', so every gate in it is merely one ALTERNATIVE -- '&&' binds tighter, and the other side of that '||' publishes on its own. if: ${publish_if:-<absent>}"
fi

tier_b_success_conjunct=0
while IFS= read -r term; do
  if is_tier_b_success_test "${term}"; then
    tier_b_success_conjunct=1
  fi
done <<EOF
$(printf '%s\n' "${publish_if}" | top_terms '&')
EOF

if [ "${tier_b_success_conjunct}" -eq 0 ]; then
  violation publish-image-requires-tier-b-success \
    "publish-image's condition has no MANDATORY top-level conjunct requiring the picture gate to have succeeded; with its !cancelled() a SKIPPED gate would no longer stop the push. Write it as one top-level '&&' term spelled \"needs.tier-b-visual-e2e.result == 'success'\" (or that with the operands reversed, or either wrapped in parentheses) -- a term nested inside a '||' is an alternative, not a requirement. if: ${publish_if:-<absent>}"
fi

# --- 3. the Release is wired to the picture gate too ----------------------
if ! contains_word 'tier-b-visual-e2e' "${release_needs}"; then
  violation call-release-needs-tier-b \
    "call-release does not need tier-b-visual-e2e, so a GitHub Release can be cut for a commit whose picture was never verified. needs: ${release_needs:-<absent>}"
fi

# --- 4. ... by DEFAULT skip propagation, which a status function disables --
# call-release's condition deliberately carries no always()/success()/
# failure()/cancelled(). That absence is what keeps GitHub's default rule ("a
# job is skipped when a job it needs did not succeed") in force, which is what
# makes an unavailable GPU runner block the release instead of being waved
# through. Adding any status function here silently converts a blocked release
# into a published one.
for fn in 'always(' 'success(' 'failure(' 'cancelled('; do
  if contains_word "${fn}" "${release_if}"; then
    violation call-release-carries-no-status-function \
      "call-release's condition contains '${fn}'. A status function overrides GitHub's default skip propagation, so a SKIPPED tier-b-visual-e2e would stop blocking the Release. if: ${release_if}"
  fi
done

# --- 5. no gate may be advisory ------------------------------------------
for job in "${GATE_JOBS[@]}"; do
  body="$(job_body "${job}")"
  if [ -z "${body}" ]; then
    violation gate-job-has-no-continue-on-error \
      "gate job '${job}' is not defined in ${WORKFLOW}"
    continue
  fi
  if contains_word 'continue-on-error' "${body}"; then
    violation gate-job-has-no-continue-on-error \
      "gate job '${job}' carries continue-on-error, which turns a gate into a suggestion"
  fi
done

# --- 6. a report-only job may only ADD a failure --------------------------
while read -r job; do
  [ -n "${job}" ] || continue
  job_needs="$(job_key "${job}" needs)"
  [ -n "${job_needs}" ] || continue
  for report in "${REPORT_ONLY_JOBS[@]}"; do
    if contains_word "${report}" "${job_needs}"; then
      violation no-job-needs-a-report-only-job \
        "job '${job}' needs the report-only job '${report}'. Report-only jobs use always() and exist to add a failure; nothing may depend on one."
    fi
  done
done <<EOF
$(list_jobs)
EOF

# --- 7. a tag push starts this workflow at all ----------------------------
if [ -z "$(tag_trigger_globs)" ]; then
  violation workflow-triggers-on-tag-push \
    "on.push.tags declares no patterns, so a tag push does not start this workflow and the picture gate never runs for a release"
fi

# --- 8. ... and reaches the picture gate on EVERY tag push ----------------
# Two halves, both required. The condition must contain the bare tag test as
# one of its top-level alternatives, AND must have no top-level `&&` -- an
# added `&& github.event_name != 'schedule'` would leave the alternative
# present while making the whole condition false for a tag push.
if [ -z "${tier_b_if}" ]; then
  violation tier-b-reachable-on-every-tag-push \
    "tier-b-visual-e2e has no job-level condition to check; is the job still there?"
else
  if [ "$(printf '%s\n' "${tier_b_if}" | top_terms '&' | wc -l)" -ne 1 ]; then
    violation tier-b-reachable-on-every-tag-push \
      "tier-b-visual-e2e's condition has a top-level '&&', so it is no longer true for every tag push. if: ${tier_b_if}"
  fi
  if ! printf '%s\n' "${tier_b_if}" | top_terms '|' \
      | grep -qxF "startsWith(github.ref, 'refs/tags/')"; then
    violation tier-b-reachable-on-every-tag-push \
      "tier-b-visual-e2e's condition has no bare \"startsWith(github.ref, 'refs/tags/')\" alternative, so a tag push can reach the Release without the picture gate. if: ${tier_b_if}"
  fi
fi

# --- 9. the one need that must never be skipped ---------------------------
# tier-b-visual-e2e needs verify-tag-shape, and a SKIPPED need skips its
# dependent. verify-tag-shape carries no job-level `if:` precisely so it can
# never be skipped; the tag check is guarded per-step instead. Give it an
# `if:` and the picture gate becomes skippable on paths nobody intended.
if [ -n "$(job_key verify-tag-shape if)" ]; then
  violation verify-tag-shape-has-no-job-level-if \
    "verify-tag-shape has a job-level 'if:'. It is a need of the picture gate, and a skipped need skips its dependent, so this job must always run. Guard the tag check per-step instead."
fi

if [ "${violations}" -gt 0 ]; then
  printf 'check_release_gates: %s violation(s) in %s\n' \
    "${violations}" "${WORKFLOW}" >&2
  exit 1
fi

printf 'check_release_gates: %s holds the release invariant\n' "${WORKFLOW}"
