#!/usr/bin/env bash
#
# Refuse a release whose picture left no evidence.
#
# WHY THIS IS A SCRIPT AND NOT AN `if [ -z ... ]` IN THE WORKFLOW
# ---------------------------------------------------------------
# It was inline shell for one round. Round 10's reviewer neutered it four
# ways, each one line, each leaving check_release_gates.py green:
#
#   attestation: ${{ steps.acceptance.outputs.attestation || 'ok' }}
#   ATTESTATION: ${{ needs...attestation }}.        <- ref plus one character
#   if [ -z ... ]; then echo warn; fi; if false; then exit 1; fi
#   ...an `exit 1` inside a heredoc body
#
# The checker was asking "does this shell text look like it fails on empty?",
# which is an open-ended question about a Turing-complete language, and every
# near-miss walked past it. As a pinned script the question becomes "is this
# job's work exactly `bash script/ci/require_attestation.sh`?" -- the same
# question already asked of the Tier B driver, answered by the same machinery
# (GATE_WORK_DRIVERS), with `shell:`, `working-directory:`, `env:`,
# `defaults.run`, `container:`, `services:` and the runner file variables all
# refused on it for free.
#
# Exit 0 only when the attestation is a non-empty summary from a run that
# sampled a frame. Everything else exits non-zero, which blocks the release.
set -euo pipefail

log() { printf '[require-attestation] %s\n' "$*"; }
fail() { printf '[require-attestation] FAIL: %s\n' "$*" >&2; }

attestation="${ATTESTATION:-}"

if [ -z "${attestation}" ]; then
  fail "tier-b-visual-e2e reported success but produced no attestation."
  fail "No frame was sampled for ${GITHUB_SHA:-<unknown commit>}."
  fail "Refusing to release a version whose picture was not verified."
  exit 1
fi

# The summary the driver emits is "<W>x<H> meanLuma=<n> brightFraction=<n>".
# Shape-checking it costs nothing and makes a hand-written placeholder --
# `ok`, `true`, a single dot -- fail here rather than read as a picture.
if ! printf '%s' "${attestation}" \
  | grep -qE '^[0-9]+x[0-9]+ meanLuma=[0-9.e+-]+ brightFraction=[0-9.e+-]+$'; then
  fail "attestation is not a frame summary: ${attestation}"
  exit 1
fi

log "picture verified for ${GITHUB_SHA:-<local>}: ${attestation}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf 'Picture verified for `%s`: %s\n' \
    "${GITHUB_SHA:-<local>}" "${attestation}" >>"${GITHUB_STEP_SUMMARY}"
fi
