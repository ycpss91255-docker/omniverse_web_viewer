#!/usr/bin/env bash
#
# Tier B visual acceptance (#48) -- in-container runner.
#
# Runs INSIDE the Dockerfile `e2e-test` stage, but at container RUNTIME (not as
# a build RUN like run-in-image.sh): the assertion needs a live Kit producer on
# the host network, which no `docker build` can reach. `e2e-test` is FROM
# runtime, so this container already carries BOTH the real served dist and
# Playwright + Chromium -- one container is the viewer AND the browser, which
# is also why nothing here has to cross a container boundary to reach the page.
#
# It:
#   1. renders the sentinel templates + serves /app/stream-only/dist through the
#      PRODUCTION entrypoint, pointed at the REAL producer (SIGNALING_SERVER /
#      SIGNALING_PORT) instead of the tier-1 dead host;
#   2. waits for the static server to answer;
#   3. runs ONLY the chromium-tier-b Playwright project;
#   4. tears the server down on every exit path.
#
# stream-only ONLY, deliberately -- see the scope note in tier-b-visual.spec.ts
# (#18: usd-viewer blanks against Isaac-family Kit apps by design).
#
# Required env (supplied by script/ci/tier_b_visual_e2e.sh):
#   SIGNALING_SERVER   producer host the viewer dials
#   SIGNALING_PORT     producer signaling port
# Optional env:
#   SERVE_PORT         static server port (default 5174)
#   OWV_ARTIFACT_DIR   writable dir for evidence (frame PNG, stats, traces)
#
# A non-zero Playwright exit is the acceptance failing, and propagates.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="stream-only"
SERVE_PORT="${SERVE_PORT:-5174}"
BASE_URL="http://127.0.0.1:${SERVE_PORT}"
SERVE_LOG="/tmp/serve-tier-b.log"

: "${SIGNALING_SERVER:?SIGNALING_SERVER is required (the producer host)}"
: "${SIGNALING_PORT:?SIGNALING_PORT is required (the producer signaling port)}"

server_pid=""

stop_server() {
  if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  server_pid=""
}
trap stop_server EXIT

wait_for_port() {
  local url="$1"
  local _
  for _ in $(seq 1 60); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "tier-b: server at ${url} never came up" >&2
  return 1
}

echo "=== tier-b: mode=${MODE} serve=${SERVE_PORT} producer=${SIGNALING_SERVER}:${SIGNALING_PORT} ==="

# MEDIA_PORT deliberately UNSET: it renders to the literal null, so the library
# negotiates media via SDP (D1). Pinning it here would assert a knob rather than
# a picture, and would have to agree with whatever the producer's Kit chose.
env \
  SIGNALING_SERVER="${SIGNALING_SERVER}" \
  SIGNALING_PORT="${SIGNALING_PORT}" \
  VIEWER_UI_MODE="${MODE}" \
  SERVE_PORT="${SERVE_PORT}" \
  /entrypoint.sh serve -s "/app/${MODE}/dist" -l "${SERVE_PORT}" >"${SERVE_LOG}" 2>&1 &
server_pid="$!"

if ! wait_for_port "${BASE_URL}"; then
  cat "${SERVE_LOG}" >&2 || true
  exit 1
fi

rc=0
(
  cd "${E2E_DIR}"
  OWV_BASE_URL="${BASE_URL}" \
  OWV_MODE="${MODE}" \
  OWV_ARTIFACT_DIR="${OWV_ARTIFACT_DIR:-}" \
    npx playwright test --project=chromium-tier-b
) || rc=$?

if [ "${rc}" -ne 0 ]; then
  echo "=== tier-b: FAILED (playwright exit ${rc}); serve log follows ===" >&2
  tail -n 40 "${SERVE_LOG}" >&2 || true
  exit "${rc}"
fi

echo "=== tier-b: PASS -- a real browser rendered a real, non-black frame ==="
