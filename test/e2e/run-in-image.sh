#!/usr/bin/env bash
#
# Tier-1 browser config-dial e2e -- in-image gate runner.
#
# Runs inside the Dockerfile `e2e-test` stage (FROM runtime), so it exercises
# the REAL served dists at /app/<mode>/dist via the production entrypoint. For
# each viewer mode it:
#   1. renders the sentinel templates + serves the dist (the entrypoint does the
#      sed render, then exec's `serve`), using DISTINCTIVE test values so a stale
#      bundle would fail the dial assertion;
#   2. waits for the static server port to answer;
#   3. runs Playwright (Chromium, headless) with OWV_* env telling the spec what
#      to expect;
#   4. tears the server down.
# The two per-PR projects are named EXPLICITLY: the Tier B visual acceptance
# (#48, project chromium-tier-b) lives in the same directory but needs a real
# GPU producer, so it must never be picked up by this gate. See run-tier-b.sh.
# They are also run ONE PER INVOCATION rather than in a single multi-project
# selection, so Playwright's "No tests found" guard applies to each suite
# individually -- see the note above the loop in run_mode.
# A non-zero Playwright exit fails the build (RUN propagates the exit code).
#
# The entrypoint itself backgrounds nothing; it exec's the CMD. We therefore run
# `entrypoint.sh serve ...` in the background here and capture its PID to stop it.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Distinctive injected values -- chosen so they cannot collide with any baked
# default (127.0.0.1 / 49100), proving the rendered bundle, not a default, wins.
#
# TEST_SIGNALING_PORT USED TO BE 49100, i.e. exactly the default this comment
# claims it cannot collide with (Dockerfile ENV, entrypoint fallback and
# overlay/stream.config.json all say 49100). The port assertion in
# config-dial.spec.ts therefore passed identically whether SIGNALING_PORT was
# honoured or the entrypoint had fallen back to its own default -- and no other
# per-PR test rendered a non-default port either, so a regression that dropped
# SIGNALING_PORT would have shipped on a green PR and been caught only by the
# nightly GPU job. 49177 cannot be a default of anything here.
TEST_SERVER="10.20.30.40"
TEST_SIGNALING_PORT="49177"
TEST_MEDIA_PORT="47998"

# The per-PR projects, named EXPLICITLY so the Tier B visual acceptance (#48,
# project chromium-tier-b) can share this directory without ever being picked
# up here. Run ONE AT A TIME -- see run_mode below for why that matters.
E2E_PROJECTS=(chromium chromium-loopback)

server_pid=""

wait_for_port() {
  local url="$1"
  local _
  for _ in $(seq 1 60); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "e2e: server at ${url} never came up" >&2
  return 1
}

stop_server() {
  if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  server_pid=""
}

# run_mode <mode> <serve_port> [media_port]
# Renders + serves the given mode, then runs Playwright against it.
run_mode() {
  local mode="$1"
  local serve_port="$2"
  local media_port="${3:-}"
  local base_url="http://127.0.0.1:${serve_port}"

  echo "=== e2e: mode=${mode} port=${serve_port} media=${media_port:-<unset>} ==="

  # The entrypoint reads these env vars, renders /app/<mode>/dist/assets/*.js.tmpl,
  # then exec's the serve command we pass as args.
  local -a env_kv=(
    "SIGNALING_SERVER=${TEST_SERVER}"
    "SIGNALING_PORT=${TEST_SIGNALING_PORT}"
    "VIEWER_UI_MODE=${mode}"
    "SERVE_PORT=${serve_port}"
  )
  if [ -n "${media_port}" ]; then
    env_kv+=("MEDIA_PORT=${media_port}")
  fi

  env "${env_kv[@]}" /entrypoint.sh \
    serve -s "/app/${mode}/dist" -l "${serve_port}" >/tmp/serve-"${mode}".log 2>&1 &
  server_pid="$!"

  if ! wait_for_port "${base_url}"; then
    cat /tmp/serve-"${mode}".log >&2 || true
    stop_server
    return 1
  fi

  # ONE PROJECT PER INVOCATION, deliberately. Playwright's "No tests found"
  # guard is evaluated over the WHOLE selection, so
  # `--project=chromium --project=chromium-loopback` in a single run is silent
  # about a project that matched zero spec files: verified against the pinned
  # @playwright/test 1.62.1, selecting the loopback project ALONE with its spec
  # absent gives `Error: No tests found` and exit 1, while selecting both gives
  # `1 skipped` and exit 0. Renaming or losing a spec file would therefore drop
  # it from the per-PR gate while this script still printed
  # `=== e2e: all modes passed ===`. Selecting one project at a time puts each
  # suite back under that guard individually.
  local rc=0
  local project
  for project in "${E2E_PROJECTS[@]}"; do
    (
      cd "${E2E_DIR}"
      OWV_BASE_URL="${base_url}" \
      OWV_MODE="${mode}" \
      OWV_EXPECT_SERVER="${TEST_SERVER}" \
      OWV_EXPECT_PORT="${TEST_SIGNALING_PORT}" \
      OWV_EXPECT_MEDIA="${media_port}" \
        npx playwright test --project="${project}"
    ) || rc=$?
    if [ "${rc}" -ne 0 ]; then
      break
    fi
  done

  stop_server
  return "${rc}"
}

trap stop_server EXIT

# stream-only, with MEDIA_PORT pinned (D1: asserts the media knob round-trips).
run_mode "stream-only" 5174 "${TEST_MEDIA_PORT}"

# usd-viewer, no media (upstream native SDP negotiation; black-box dial check).
run_mode "usd-viewer" 5173

echo "=== e2e: all modes passed ==="
