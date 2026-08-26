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
#
# This is a NAME LIST, and a name list only knows the jobs that existed when
# it was written. It is not what decides which jobs must carry the picture
# gate -- that set is DERIVED from the file by publishing_jobs() below,
# because a job added tomorrow is invisible here. Keep this list for the jobs
# whose ROLE is not derivable (verify-tag-shape and tier-b-visual-e2e publish
# nothing; they are gates), and let the derivation cover the rest.
GATE_JOBS=(
  call-docker-build
  verify-tag-shape
  call-release
  publish-image
  tier-b-visual-e2e
)

# Textual evidence that a job can put something PERMANENT somewhere: a
# registry login, a pushing build, a Release action, or a token scope that
# only a publishing job needs.
#
# WHY DERIVED. GATE_JOBS above is an allowlist, so a NEW publishing job is
# invisible to every check keyed off it: a `publish-image-hotfix:` job that
# logs in to GHCR and pushes, with `needs: [call-docker-build]` and no picture
# gate at all, was caught by nothing. The rule is not about the five names
# anyone happened to write down -- it is that anything which publishes stands
# behind the gate.
#
# WHAT IT CANNOT SEE (stated because an over-claimed gate is worse than a
# named-scope one): a job that publishes through a mechanism none of these
# strings name -- a `curl -T` to some registry with a secret, a third-party
# action nobody here has heard of, an inline `docker` invocation spelled
# differently -- is not derived and is therefore not required to carry the
# gate. Widening this list is the whole cost of closing that.
PUBLISH_SIGNALS=(
  'packages: write'
  'contents: write'
  'docker/login-action'
  'push: true'
  'action-gh-release'
  'release-worker'
  'gh release create'
  'docker push'
  'npm publish'
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

# job_steps <job>: one line per step of <job>, as
#
#     <step-level if:><SOH><the whole step, folded onto one line>
#
# Nothing below job level was examined before this existed, and that was a
# hole the size of the gate itself: a gate job whose WORK STEP is skipped
# still concludes `success`, which is all any `needs:` / `result` check
# downstream can see. `if: github.event_name == 'schedule'` on the Tier B
# acceptance STEP (not the job) publishes an image with no picture ever taken,
# and `if: false` on verify-tag-shape's only step lets a malformed tag through
# to the Release -- both under a green board.
#
# A step opens at 6-space `- `; its own keys are at 8; a folded `if: >-`
# continues at 10. An 8-space key ends any folded value being accumulated, so
# a `run: |` block body can never be mistaken for more of an `if:`.
job_steps() {
  job_body "$1" | awk '
    # A step `if:` reaches here as GitHub would evaluate it: the block marker
    # of a folded `>-` scalar and a `${{ }}` wrapper are notation, not part of
    # the expression, so both are stripped before any caller compares it.
    function unwrap(v) {
      sub(/^[|>][-+]?[[:space:]]*/, "", v)
      sub(/^[$][{][{][[:space:]]*/, "", v)
      sub(/[[:space:]]*[}][}]$/, "", v)
      return v
    }
    function flush() {
      if (instep) { printf "%s\001%s\n", unwrap(ifv), body }
      instep = 0; inif = 0; ifv = ""; body = ""
    }
    /^    steps:[[:space:]]*$/ { insteps = 1; next }
    insteps && /^    [^[:space:]]/ { flush(); insteps = 0 }
    !insteps { next }
    /^      - / {
      flush()
      instep = 1
      line = $0; sub(/^      - /, "", line); body = line
      if (line ~ /^if:/) {
        ifv = line; sub(/^if:[[:space:]]*/, "", ifv); inif = 1
      }
      next
    }
    instep {
      if ($0 ~ /^        [A-Za-z0-9_-]+:/) {
        inif = 0
        if ($0 ~ /^        if:/) {
          ifv = $0; sub(/^        if:[[:space:]]*/, "", ifv); inif = 1
        }
      } else if (inif && $0 ~ /^          /) {
        l = $0; sub(/^[[:space:]]+/, "", l); ifv = ifv " " l
      }
      l = $0; sub(/^[[:space:]]+/, "", l); body = body " " l
      next
    }
    END { flush() }
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

# needs_list <job>: the job names in <job>'s `needs:`, one per line.
#
# A SUBSTRING TEST IS NOT MEMBERSHIP, and the difference publishes releases.
# `contains_word 'tier-b-visual-e2e' "${release_needs}"` is satisfied by a job
# merely NAMED after the gate: add an `always()`-gated
# `tier-b-visual-e2e-summary` and point call-release at that, and a Release is
# cut for a commit whose Tier B failed while every check here passes. Both the
# flow (`[a, b]`) and block (`- a`) sequence spellings are accepted, as is a
# bare scalar.
needs_list() {
  job_key "$1" needs | awk '
    {
      gsub(/[][,]/, " ")
      n = split($0, a, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (a[i] != "" && a[i] != "-") { print a[i] }
      }
    }
  '
}

# needs_job <job> <needed>: true when <needed> is an ITEM of <job>'s needs.
needs_job() {
  needs_list "$1" | grep -qxF "$2"
}

# publishing_jobs: every job whose body carries one of PUBLISH_SIGNALS, in
# file order. Derived rather than listed; see PUBLISH_SIGNALS for what that
# buys and what it still cannot see.
publishing_jobs() {
  local job body signal
  while IFS= read -r job; do
    [ -n "${job}" ] || continue
    body="$(job_body "${job}")"
    for signal in "${PUBLISH_SIGNALS[@]}"; do
      if contains_word "${signal}" "${body}"; then
        printf '%s\n' "${job}"
        break
      fi
    done
  done <<EOF
$(list_jobs)
EOF
}

# has_top_level_or <expr>: true when <expr> has a `||` at parenthesis depth 0,
# i.e. when everything else in it is merely one ALTERNATIVE (`&&` binds
# tighter than `||`).
has_top_level_or() {
  [ "$(printf '%s\n' "$1" | top_terms '|' | wc -l)" -ne 1 ]
}

# has_tier_b_success_conjunct <expr>: true when one top-level `&&` term of
# <expr> IS the tier-b success test (not merely contains it).
has_tier_b_success_conjunct() {
  local term
  while IFS= read -r term; do
    if is_tier_b_success_test "${term}"; then
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$1" | top_terms '&')
EOF
  return 1
}

# has_status_function <expr>: true when <expr> contains always() / success() /
# failure() / cancelled(). Substring IS the property here: the rule is that
# the token must not appear anywhere.
has_status_function() {
  local fn
  for fn in 'always(' 'success(' 'failure(' 'cancelled('; do
    if contains_word "${fn}" "$1"; then
      return 0
    fi
  done
  return 1
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
# is_tag_ref_test <term>: true when <term> is a test for "this ref is a tag".
# A closed SET of spellings for the same reason as is_tier_b_success_test --
# and this repo already uses two of them ten lines apart, so accepting only
# one would report the shipped workflow's own verify-tag-shape step guard as a
# violation.
is_tag_ref_test() {
  case "$1" in
    "startsWith(github.ref, 'refs/tags/')") return 0 ;;
    "(startsWith(github.ref, 'refs/tags/'))") return 0 ;;
    "github.ref_type == 'tag'") return 0 ;;
    "(github.ref_type == 'tag')") return 0 ;;
    "'tag' == github.ref_type") return 0 ;;
    "('tag' == github.ref_type)") return 0 ;;
    *) return 1 ;;
  esac
}

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
# MEMBERSHIP, not substring: see needs_list.
if ! needs_job publish-image tier-b-visual-e2e; then
  violation publish-image-needs-tier-b \
    "publish-image does not have tier-b-visual-e2e as an ITEM of its needs, so an image can be pushed for a commit whose picture was never verified. A job merely named after the gate does not count. needs: ${publish_needs:-<absent>}"
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
if has_top_level_or "${publish_if}"; then
  violation publish-image-gate-is-not-optional \
    "publish-image's condition has a top-level '||', so every gate in it is merely one ALTERNATIVE -- '&&' binds tighter, and the other side of that '||' publishes on its own. if: ${publish_if:-<absent>}"
fi

if ! has_tier_b_success_conjunct "${publish_if}"; then
  violation publish-image-requires-tier-b-success \
    "publish-image's condition has no MANDATORY top-level conjunct requiring the picture gate to have succeeded; with its !cancelled() a SKIPPED gate would no longer stop the push. Write it as one top-level '&&' term spelled \"needs.tier-b-visual-e2e.result == 'success'\" (or that with the operands reversed, or either wrapped in parentheses) -- a term nested inside a '||' is an alternative, not a requirement. if: ${publish_if:-<absent>}"
fi

# --- 3. the Release is wired to the picture gate too ----------------------
# MEMBERSHIP again, and here it is load-bearing in the most direct way: a
# substring test is satisfied by an `always()`-gated job called
# `tier-b-visual-e2e-summary`, which cuts a Release for a commit whose Tier B
# failed.
if ! needs_job call-release tier-b-visual-e2e; then
  violation call-release-needs-tier-b \
    "call-release does not have tier-b-visual-e2e as an ITEM of its needs, so a GitHub Release can be cut for a commit whose picture was never verified. A job merely named after the gate does not count. needs: ${release_needs:-<absent>}"
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
# Over the named gate jobs AND every derived publishing job, so a job invented
# after this list was written cannot opt out of the rule by not being on it.
PUBLISHING_JOBS="$(publishing_jobs)"

while IFS= read -r job; do
  [ -n "${job}" ] || continue
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
done <<EOF
$(printf '%s\n' "${GATE_JOBS[@]}" "${PUBLISHING_JOBS}" | grep -v '^$' | sort -u)
EOF

# --- 6. a report-only job may only ADD a failure --------------------------
while read -r job; do
  [ -n "${job}" ] || continue
  job_needs="$(job_key "${job}" needs)"
  [ -n "${job_needs}" ] || continue
  for report in "${REPORT_ONLY_JOBS[@]}"; do
    if needs_job "${job}" "${report}"; then
      violation no-job-needs-a-report-only-job \
        "job '${job}' needs the report-only job '${report}'. Report-only jobs use always() and exist to add a failure; nothing may depend on one."
    fi
  done
done <<EOF
$(list_jobs)
EOF

# --- 6b. ... and neither may anything else that carries a status function --
# Property 6 is a NAME LIST, so it only knows the two report jobs that exist
# today. The rule underneath it is not about their names: a job whose own `if:`
# carries always()/success()/failure()/cancelled() runs on paths where its
# needs did not succeed, so depending on one imports exactly the escape the
# picture-gate rule forbids -- and a NEW such job is invisible to a name list.
# That is the second half of the decoy: `tier-b-visual-e2e-summary`, `if:
# always()`, needed by call-release.
#
# The same loop refuses a `needs:` naming a job that does not exist. GitHub
# errors on that, but this checker would otherwise read the dangling name's
# absent `if:` as "no status function" and report the invariant as held for a
# workflow that cannot run at all.
all_jobs="$(list_jobs)"
while IFS= read -r job; do
  [ -n "${job}" ] || continue
  while IFS= read -r need; do
    [ -n "${need}" ] || continue
    if ! printf '%s\n' "${all_jobs}" | grep -qxF "${need}"; then
      violation needs-name-a-job-that-exists \
        "job '${job}' needs '${need}', which is not a job in ${WORKFLOW}"
      continue
    fi
    need_if="$(job_key "${need}" if)"
    for fn in 'always(' 'success(' 'failure(' 'cancelled('; do
      if contains_word "${fn}" "${need_if}"; then
        violation no-job-needs-a-status-gated-job \
          "job '${job}' needs '${need}', whose own condition contains '${fn}'. A status function makes that job run on paths where ITS needs did not succeed, so waiting on it imports the escape the picture-gate rule forbids. if: ${need_if}"
      fi
    done
  done <<NEEDS
$(needs_list "${job}")
NEEDS
done <<EOF
${all_jobs}
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

# --- 10. a gate job's WORK may not be conditionally skipped ---------------
# Everything above reads job level, and a job's `result` is all a `needs:` or
# a `needs.*.result` check can see -- so a job that RUNS but does NOTHING
# reports `success` and satisfies every property above it. Two mutations do
# exactly that, with no override input and no status function anywhere:
#
#   `if: github.event_name == 'schedule'` on the Tier B acceptance STEP: the
#   gate job runs, the one step that boots a producer and looks at a frame is
#   skipped, the job concludes `success`, publish-image is satisfied, and the
#   image publishes with no picture ever taken.
#
#   `if: false` on verify-tag-shape's only step: the shape check never runs,
#   the job succeeds, and a tag the image-tag deriver cannot publish reaches
#   call-release -- the exact ordering failure that job was created to stop.
#
# The rule: in a gate job, a step that runs one of this repo's `script/ci/`
# helpers IS the job's work and must be unconditional. The one exception is
# declared rather than inferred -- verify-tag-shape's deriver step is the
# per-step tag guard property 9 requires it to have INSTEAD of a job-level
# `if:`, so it may carry a condition, but only a tag-ref test.
#
# WHAT THIS DOES NOT SEE: a gate job's work that is not a `script/ci/` call
# (an inline `run:` block, a third-party action) can still be given an `if:`
# and this check will not notice. It is the strongest derivation available
# from the file without evaluating what a step does.
for job in "${GATE_JOBS[@]}"; do
  [ -n "$(job_body "${job}")" ] || continue
  work_steps=0
  while IFS="$(printf '\001')" read -r step_if step_body; do
    [ -n "${step_body}" ] || continue
    case "${step_body}" in
      *script/ci/*) ;;
      *) continue ;;
    esac
    # A `--print-<something>` invocation asks the helper a question (the Tier B
    # driver is asked for the producer image reference so the digest is not
    # copied into this file twice); it is not the job's work, so it does not
    # satisfy the "there is still work here" count below. It is still required
    # to be unconditional -- a skipped query fails the step that uses it.
    case "${step_body}" in
      *--print-*) ;;
      *) work_steps=$((work_steps + 1)) ;;
    esac
    [ -n "${step_if}" ] || continue
    if [ "${job}" = "verify-tag-shape" ] && is_tag_ref_test "${step_if}"; then
      continue
    fi
    violation gate-job-work-step-is-unconditional \
      "gate job '${job}' has a step guarded by 'if: ${step_if}' that runs one of this repo's script/ci/ helpers. A gate job whose work step is skipped still concludes 'success', which is all any downstream needs/result check can see -- so this publishes with the gate never having run. Step: ${step_body}"
  done <<EOF
$(job_steps "${job}")
EOF
  if [ "${work_steps}" -eq 0 ]; then
    case "${job}" in
      tier-b-visual-e2e | verify-tag-shape)
        violation gate-job-work-step-is-unconditional \
          "gate job '${job}' no longer runs any script/ci/ helper, so there is nothing left in it for this check -- or for the gate -- to be about"
        ;;
    esac
  fi
done

# --- 10b. the picture gate runs where a picture can be taken --------------
# `runs-on: [self-hosted, gpu]` is not a performance choice. The whole job is
# "boot a real Kit producer and assert a browser renders a non-black frame
# from it", and no hosted runner has NVENC -- so `runs-on: ubuntu-latest` here
# does not slow the gate down, it removes it: the job cannot do its work, and
# whatever it then reports is not a picture. Nothing pinned it.
tier_b_runs_on="$(job_key tier-b-visual-e2e runs-on)"
if ! contains_word 'self-hosted' "${tier_b_runs_on}" \
   || ! contains_word 'gpu' "${tier_b_runs_on}"; then
  violation tier-b-runs-on-the-gpu-runner \
    "tier-b-visual-e2e must run on [self-hosted, gpu]: it boots a real Kit producer and asserts a real browser renders a real frame, and no hosted runner has NVENC. Moving it off the GPU does not slow the gate down, it removes it. runs-on: ${tier_b_runs_on:-<absent>}"
fi

# --- 11. EVERY job that can publish stands behind the picture gate --------
# Properties 1-4 name call-release and publish-image, because those are the
# two jobs that published anything when they were written. That is an
# allowlist, and an allowlist cannot see a new entry: a `publish-image-hotfix:`
# job that logs in to GHCR and pushes with `needs: [call-docker-build]` and no
# gate at all was caught by nothing in this file.
#
# So the set is DERIVED (publishing_jobs / PUBLISH_SIGNALS) and each member
# must be behind the gate by ONE OF THE TWO MECHANISMS this workflow uses --
# they are not interchangeable and each is only safe on its own terms:
#
#   A. no status function in the job's condition. GitHub's default rule ("a
#      job is skipped when a job it needs did not succeed") then applies, and
#      that default is what makes an unavailable GPU runner block the release.
#      This is call-release.
#
#   B. a status function, plus an explicit MANDATORY top-level conjunct
#      requiring the gate to have succeeded, and no top-level `||` for that
#      conjunct to be an alternative of. This is publish-image, whose
#      `!cancelled()` it needs because call-release is legitimately skipped on
#      both dispatch paths.
#
# Either way, `needs:` must have the gate as an item -- without that the
# condition has no result to read and GitHub evaluates `needs.<job>.result` to
# the empty string.
if [ -z "${PUBLISHING_JOBS}" ]; then
  violation publishing-jobs-are-identifiable \
    "no job in ${WORKFLOW} carries any evidence of publishing (registry login, push: true, a Release action, packages/contents write). Either the publish path was removed, or it is now spelled in a way this checker cannot see -- and a gate that cannot find the thing it gates reports an invariant that protects nothing"
fi

while IFS= read -r job; do
  [ -n "${job}" ] || continue
  # The gate cannot be required to stand behind itself.
  if [ "${job}" = "tier-b-visual-e2e" ]; then
    continue
  fi
  if ! needs_job "${job}" tier-b-visual-e2e; then
    job_needs="$(job_key "${job}" needs)"
    violation publishing-job-is-behind-the-picture-gate \
      "job '${job}' can publish (it carries a registry login, a pushing build, a Release action or a write token scope) but does not have tier-b-visual-e2e as an item of its needs, so it can publish for a commit whose picture was never verified. needs: ${job_needs:-<absent>}"
    continue
  fi
  job_if="$(job_key "${job}" if)"
  if has_status_function "${job_if}" \
     && ! { has_tier_b_success_conjunct "${job_if}" \
            && ! has_top_level_or "${job_if}"; }; then
    violation publishing-job-is-behind-the-picture-gate \
      "job '${job}' can publish and its condition carries a status function, which overrides GitHub's default skip propagation -- so a SKIPPED picture gate no longer stops it. A job in that position must ALSO require the gate explicitly, as a mandatory top-level conjunct \"needs.tier-b-visual-e2e.result == 'success'\" with no top-level '||' in the condition. if: ${job_if:-<absent>}"
  fi
done <<EOF
${PUBLISHING_JOBS}
EOF

if [ "${violations}" -gt 0 ]; then
  printf 'check_release_gates: %s violation(s) in %s\n' \
    "${violations}" "${WORKFLOW}" >&2
  exit 1
fi

printf 'check_release_gates: %s holds the release invariant\n' "${WORKFLOW}"
