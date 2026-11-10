#!/usr/bin/env bash
#
# tier_b_prepare.sh -- everything the Tier B job does on the GPU host BEFORE
# the acceptance driver runs.
#
# Run by the org reusable workflow
# (ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml, its
# `prepare-script` input) after checkout and before `run-script`, which is
# script/ci/tier_b_visual_e2e.sh. It sits OUTSIDE the run-script's
# step-timeout-minutes on purpose: a multi-GB image pull or a cold build must
# not eat the 45 minutes the acceptance step is given.
#
# These four commands used to be four steps of the tier-b-visual-e2e job in
# .github/workflows/main.yaml, and check_release_gates.py pinned each one in
# GATE_JOB_ALLOWED_STEPS. A reusable-workflow call has no steps of its own, so
# the pin moved here: check_release_gates.py compares this file's command
# lines, exactly, against TIER_B_PREPARE_LINES. An extra or edited command is
# a violation until that table says otherwise, in the same diff, where a
# reviewer sees it -- this script runs on a persistent, shared,
# root-equivalent host, ahead of the step that decides whether a version may
# publish.
#
# Nothing here writes $GITHUB_OUTPUT: the reusable workflow returns only the
# run-script's outputs (script-outputs), so the attestation can only come
# from the driver.
set -euo pipefail

# base detect_ws_path mis-detects the self-CI _work/<repo>/<repo> layout, so
# pin WS_PATH to the checkout root in the derived cache and the compose build
# resolves. Same fix isaac applies in stream-smoke (base#586).
./script/setup.sh apply
sed -i "s|^WS_PATH=.*|WS_PATH=${GITHUB_WORKSPACE}|" .env.generated

# The same stage the per-PR gate builds. Building it here also re-runs the
# tier-1 in-image gate, so a Tier B run can never pass on a stale image.
./script/build.sh -t e2e-test

# Explicit, so a registry problem is distinguishable from an acceptance
# failure. The reference comes FROM the driver: the producer is pinned by
# DIGEST there, and a second copy of that digest is a thing that can drift
# from the one actually run.
docker pull "$(bash script/ci/tier_b_visual_e2e.sh --print-producer-image)"
