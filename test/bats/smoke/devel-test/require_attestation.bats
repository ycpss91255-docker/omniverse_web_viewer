#!/usr/bin/env bats
#
# Refusal-branch coverage for script/ci/require_attestation.sh.
#
# The script exits 0 only when ATTESTATION is a non-empty string matching the
# frame-summary pattern "<W>x<H> meanLuma=<n> brightFraction=<n>". Everything
# else -- empty, unset, placeholder, malformed -- exits 1. These specs lock
# every refusal branch so a future edit cannot soften one without a red test.

SCRIPT="/ci/require_attestation.sh"

# -- refusal: empty / unset ------------------------------------------------

# why: Refusal-branch coverage for `script/ci/require_attestation.sh`, the
# shell guard that refuses a release whose picture left no evidence. The
# script exits 0 only when `ATTESTATION` is a non-empty string matching the
# frame-summary pattern `<W>x<H> meanLuma=<n> brightFraction=<n>`. Every
# other input -- empty, unset, a placeholder like `ok` or `true`, a partial
# or malformed summary, leading or trailing whitespace -- exits 1 and blocks
# the release.


# why: Empty string exits 1 with "produced no attestation"
@test "require_attestation: empty ATTESTATION is refused" {
  run env ATTESTATION="" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"produced no attestation"* ]]
}

# why: Unset variable exits 1 with "produced no attestation"
@test "require_attestation: unset ATTESTATION is refused" {
  run env -u ATTESTATION bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"produced no attestation"* ]]
}

# -- refusal: placeholders that are not frame summaries --------------------

# why: Literal `ok` does not match the frame-summary regex
@test "require_attestation: placeholder 'ok' is refused" {
  run env ATTESTATION="ok" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Literal `true` does not match
@test "require_attestation: placeholder 'true' is refused" {
  run env ATTESTATION="true" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Literal `.` does not match
@test "require_attestation: single dot is refused" {
  run env ATTESTATION="." bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Bare number does not match
@test "require_attestation: number-only string is refused" {
  run env ATTESTATION="42" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# -- refusal: partial / malformed summaries --------------------------------

# why: Partial summary with only `meanLuma`
@test "require_attestation: missing brightFraction is refused" {
  run env ATTESTATION="1920x1080 meanLuma=42" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Partial summary with only `brightFraction`
@test "require_attestation: missing meanLuma is refused" {
  run env ATTESTATION="1920x1080 brightFraction=0.65" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Summary without leading `<W>x<H>`
@test "require_attestation: missing dimensions is refused" {
  run env ATTESTATION="meanLuma=42 brightFraction=0.65" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Regex is `$`-anchored
@test "require_attestation: trailing whitespace is refused" {
  run env ATTESTATION="1920x1080 meanLuma=42 brightFraction=0.65 " bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# why: Regex is `^`-anchored
@test "require_attestation: leading whitespace is refused" {
  run env ATTESTATION=" 1920x1080 meanLuma=42 brightFraction=0.65" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a frame summary"* ]]
}

# -- acceptance: valid frame summaries -------------------------------------

# why: Canonical frame summary exits 0
@test "require_attestation: valid summary is accepted" {
  run env ATTESTATION="1920x1080 meanLuma=42 brightFraction=0.65" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"picture verified"* ]]
}

# why: `4.2e+1` matches `[0-9.e+-]+`
@test "require_attestation: scientific notation is accepted" {
  run env ATTESTATION="1920x1080 meanLuma=4.2e+1 brightFraction=6.5e-1" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"picture verified"* ]]
}

# why: `1x1` is a valid dimension pair
@test "require_attestation: small dimensions are accepted" {
  run env ATTESTATION="1x1 meanLuma=255 brightFraction=1.0" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"picture verified"* ]]
}

# -- GITHUB_SHA appears in messages ----------------------------------------

# why: Commit hash propagated to stderr
@test "require_attestation: GITHUB_SHA appears in refusal message" {
  run env ATTESTATION="" GITHUB_SHA="abc123" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abc123"* ]]
}

# why: Commit hash propagated to stdout
@test "require_attestation: GITHUB_SHA appears in success message" {
  run env ATTESTATION="800x600 meanLuma=10 brightFraction=0.2" \
          GITHUB_SHA="def456" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"def456"* ]]
}

# -- GITHUB_STEP_SUMMARY is written on success -----------------------------

# why: `GITHUB_STEP_SUMMARY` file written
@test "require_attestation: step summary is written on success" {
  local summary_file
  summary_file="$(mktemp)"
  run env ATTESTATION="800x600 meanLuma=10 brightFraction=0.2" \
          GITHUB_SHA="abc123" \
          GITHUB_STEP_SUMMARY="$summary_file" \
          bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$summary_file" ]
  grep -q "abc123" "$summary_file"
  rm -f "$summary_file"
}
