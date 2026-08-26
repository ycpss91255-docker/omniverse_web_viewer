#!/usr/bin/env bash
#
# tier_b_visual_e2e.sh -- Tier B visual acceptance driver (#48).
#
# Proves, without a human in front of a browser, that a REAL Kit producer's
# picture reaches the viewer: boots the pinned deterministic producer image
# (ghcr.io/ycpss91255-docker/isaac-stream-source, isaac#223 / isaac PR #243),
# waits for its WebRTC streaming server, then runs the `e2e-test` image against
# it. That container serves the REAL stream-only dist through the production
# entrypoint and drives headless Chromium at it (test/e2e/run-tier-b.sh ->
# tier-b-visual.spec.ts), asserting a connected RTCPeerConnection, a remote
# track, videoWidth > 0 and a sampled NON-BLACK frame.
#
# GPU host only (NVENC + RTX). Nightly / manual, never per-PR: the producer
# boots Kit, which is minutes, and contends for the GPU.
#
# ISOLATION (#48 acceptance criterion; the incident class is isaac#237 / #239 /
# #240 / #241 -- CI actors on a shared GPU host tearing down a manual stack):
#   - every container this script creates is named `owv-tierb-<instance>-*`,
#     an instance-scoped namespace no dev/demo stack can own. `_drop` REFUSES
#     to touch a name outside that prefix, so a mistyped override cannot turn
#     the teardown into someone else's outage;
#   - teardown removes ONLY those two names -- no compose project, no
#     `down --remove-orphans`, nothing that reconciles anything it does not own;
#   - ports are PROBED free before use, starting well away from the ports the
#     dev/demo stacks have historically held (5173/49100, 5174/49200);
#   - nothing here touches a compose project, an image tag or a shared name.
#
# UPSTREAM DEFECT WORKAROUND (isaac#244): in the published `:0.0.1` image
# `COPY --chmod=0644` also applied 0644 to the parent directory it created, so
# `/opt/isaac-producer` has no execute bit and the non-root image USER cannot
# traverse it -- the container exits 1 with `[Errno 13] Permission denied`
# reading its own baked driver. Running as root traverses regardless of the
# directory mode; verified working end to end on an RTX 5090. Overridable via
# TIER_B_PRODUCER_USER, so set it empty once a fixed tag is published.
#
# Env knobs (all optional):
#   TIER_B_PRODUCER_IMAGE  producer image (default: the pinned 0.0.1 tag)
#   TIER_B_PRODUCER_USER   --user for the producer (default: 0:0, isaac#244)
#   TIER_B_VIEWER_IMAGE    e2e-test image (default: from .env.generated)
#   TIER_B_INSTANCE        instance scope (default: GITHUB_RUN_ID, else $$)
#   TIER_B_SERVE_PORT      static server port (default: first free from 5399)
#   TIER_B_SIGNAL_PORT     producer signaling port (default: first free 49399)
#   TIER_B_PUBLIC_IP       publicEndpointAddress (default: 127.0.0.1)
#   TIER_B_BOOT_TIMEOUT    seconds to wait for the producer (default: 900)
#   TIER_B_ARTIFACT_DIR    evidence dir (default: <repo>/.tier-b-artifacts)
#
# Exit 0 = a real browser saw a real, non-black frame from a real producer.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PRODUCER_IMAGE="${TIER_B_PRODUCER_IMAGE:-ghcr.io/ycpss91255-docker/isaac-stream-source:0.0.1}"
PRODUCER_USER="${TIER_B_PRODUCER_USER-0:0}"
INSTANCE="${TIER_B_INSTANCE:-${GITHUB_RUN_ID:-$$}}"
PUBLIC_IP="${TIER_B_PUBLIC_IP:-127.0.0.1}"
BOOT_TIMEOUT="${TIER_B_BOOT_TIMEOUT:-900}"
ARTIFACT_DIR="${TIER_B_ARTIFACT_DIR:-${REPO_ROOT}/.tier-b-artifacts}"

# The name prefix is the isolation guarantee; keep it in ONE place.
NAME_PREFIX="owv-tierb-${INSTANCE}"
PRODUCER_NAME="${NAME_PREFIX}-producer"
VIEWER_NAME="${NAME_PREFIX}-viewer"

# The producer's own scene-ready marker, read from OUR container's log only.
#
# NOT a host port probe: the container runs --network=host, so `ss :PORT` would
# also match an unrelated Kit left running here (a false pass), and the
# signaling socket binds early in startup anyway.
#
# And NOT `Streaming server started.`, the marker isaac's Tier A smoke uses
# (script/ci/stream_smoke.sh). That is the right marker for Tier A, which only
# asks whether the streaming server came up -- but it is about 11 seconds too
# early for Tier B, which needs a scene to look at. Measured on this producer:
#   ~14s  Streaming server started.          <- signaling accepts clients
#   ~25s  app ready                          <- SimulationApp finished starting
#   ~26s  [PRODUCER] empty lit stage ...     <- scene built, camera framed
# The driver prints its own line only after `_build_empty_lit_stage()` and the
# camera-framing `app.update()` warmup, i.e. exactly when a connecting browser
# can be shown something. Connecting inside the earlier window is not merely
# early, it is worse than waiting: observed once here, the browser got a
# session and a track and decoded frames, then the session died as the driver
# took the app over -- leaving every sampled frame black and the viewer
# correctly reporting `stream ended -- the source is gone`.
READY_MARKER='[PRODUCER] empty lit stage streaming'

# Ports deliberately far from the ranges dev/demo stacks have held on this host
# (5173/49100 default, 5174/49200 demo), then probed free anyway.
SERVE_PORT_BASE=5399
SIGNAL_PORT_BASE=49399
PORT_SCAN_SPAN=50

log() { printf '[tier-b] %s\n' "$*"; }
fail() { printf '[tier-b] FAIL: %s\n' "$*" >&2; }

# _port_in_use PORT -- true when something already listens on 127.0.0.1:PORT.
# bash /dev/tcp, so this needs no ss/lsof/netstat on the runner. The probe runs
# in a subshell, so the fd closes with it and nothing leaks.
_port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null
}

# _pick_port BASE -- first free port at or above BASE (scanning PORT_SCAN_SPAN).
_pick_port() {
  local base="$1" port
  for ((port = base; port < base + PORT_SCAN_SPAN; port++)); do
    if ! _port_in_use "${port}"; then
      printf '%s\n' "${port}"
      return 0
    fi
  done
  fail "no free port in ${base}..$((base + PORT_SCAN_SPAN - 1))"
  return 1
}

# _drop NAME -- remove a container this script owns. The prefix check is the
# whole point: teardown must be incapable of reaching a name another stack
# could own, no matter what an override sets INSTANCE to.
_drop() {
  local name="$1"
  case "${name}" in
    owv-tierb-*) ;;
    *)
      fail "refusing to remove '${name}': not an owv-tierb-* container"
      return 0
      ;;
  esac
  docker rm -f "${name}" >/dev/null 2>&1 || true
}

# THE `grep -q` TRAP, and why every check below counts instead.
#
# This script runs under `set -o pipefail`. `docker ... | grep -q PATTERN`
# exits grep on its FIRST match, which closes the pipe while docker is still
# writing; docker then dies of SIGPIPE (141), and pipefail hands that 141 up as
# the pipeline's status. The `if` therefore reads "not found" for something that
# is plainly there -- and it does so only once the output is long enough for
# docker to still be writing when grep leaves, i.e. it passes in every small
# reproduction and fails against a real multi-megabyte Kit log.
#
# `grep -c` reads to EOF, so docker always finishes writing and never gets the
# signal; the count is what decides. `|| true` absorbs grep's exit 1 on zero
# matches so the count, not an exit status, is the answer in that case too.
#
# _container_exists NAME  -- a container with exactly NAME exists (any state).
_container_exists() {
  local hits
  hits="$(docker ps -a --format '{{.Names}}' | grep -cxF -- "$1" || true)"
  [ "${hits:-0}" -gt 0 ]
}

# _container_running NAME -- a container with exactly NAME is currently up.
_container_running() {
  local hits
  hits="$(docker ps --format '{{.Names}}' | grep -cxF -- "$1" || true)"
  [ "${hits:-0}" -gt 0 ]
}

# _log_contains NAME MARKER -- NAME's log (stdout+stderr) contains MARKER.
_log_contains() {
  local hits
  hits="$(docker logs "$1" 2>&1 | grep -cF -- "$2" || true)"
  [ "${hits:-0}" -gt 0 ]
}

cleanup() {
  local rc=$?
  # Save the producer log BEFORE removing it -- it is the only diagnosis a
  # nightly failure leaves behind.
  if _container_exists "${PRODUCER_NAME}"; then
    docker logs "${PRODUCER_NAME}" >"${ARTIFACT_DIR}/producer.log" 2>&1 || true
  fi
  log "teardown: dropping ${VIEWER_NAME} + ${PRODUCER_NAME}"
  _drop "${VIEWER_NAME}"
  _drop "${PRODUCER_NAME}"
  exit "${rc}"
}
trap cleanup EXIT INT TERM

# Viewer image: the e2e-test stage tag the build wrapper produces
# (${DOCKER_HUB_USER}/${IMAGE_NAME}:e2e-test). Read from the derived .env so
# this follows whatever the repo is configured as, with a plain default.
DOCKER_HUB_USER="local"
IMAGE_NAME="omniverse_web_viewer"
# shellcheck source=/dev/null
[ -f "${REPO_ROOT}/.env.generated" ] && . "${REPO_ROOT}/.env.generated"
# shellcheck source=/dev/null
[ -f "${REPO_ROOT}/.env" ] && . "${REPO_ROOT}/.env"
VIEWER_IMAGE="${TIER_B_VIEWER_IMAGE:-${DOCKER_HUB_USER}/${IMAGE_NAME}:e2e-test}"

SERVE_PORT="${TIER_B_SERVE_PORT:-$(_pick_port "${SERVE_PORT_BASE}")}"
SIGNAL_PORT="${TIER_B_SIGNAL_PORT:-$(_pick_port "${SIGNAL_PORT_BASE}")}"

# 0777: the artifact dir is bind-mounted into a container running as a
# different uid than the runner, and evidence must not be lost to a mode bit.
mkdir -p "${ARTIFACT_DIR}"
chmod 0777 "${ARTIFACT_DIR}" 2>/dev/null || true

log "instance=${INSTANCE} serve=${SERVE_PORT} signaling=${SIGNAL_PORT} public_ip=${PUBLIC_IP}"
log "producer=${PRODUCER_IMAGE}"
log "viewer=${VIEWER_IMAGE}"
log "artifacts=${ARTIFACT_DIR}"

if ! docker image inspect "${VIEWER_IMAGE}" >/dev/null 2>&1; then
  fail "viewer image ${VIEWER_IMAGE} is not present -- build it first (just build -t e2e-test)"
  exit 1
fi

# Pre-clean OUR OWN names only: a hard-killed earlier run of the same instance
# can leave the (non---rm) producer behind, and `docker run --name` would then
# fail on the conflict. Prefix-guarded, same as the teardown.
_drop "${VIEWER_NAME}"
_drop "${PRODUCER_NAME}"

# --network=host: Kit's WebRTC listen ports must be the host's, and the browser
# container shares that namespace so it reaches the producer on 127.0.0.1.
# --gpus all: NVENC encodes the frames; without it the producer has no picture
# to send.
# --ipc=host: NOT optional, and not in the producer image's documented start
# command. Kit boots fine on the default private 64 MB /dev/shm, but the
# streaming media pipeline allocates shared memory when a client ATTACHES, so
# the failure only appears once a browser connects -- which is precisely what
# Tier B does and Tier A does not. Observed here before this flag: connect,
# remote track, decoded frames, then `Stream disconnected from server,
# FrameGrabFailed.` about 16 s in, the session gone and every sampled frame
# black. isaac#233 records the same signature from the other side (a hand-built
# stream container missing --ipc=host, Kit SIGKILLed on first client connect);
# the isaac repo itself sets `ipc = host` in config/docker/setup.conf, which is
# why its own compose-run stacks never hit this and a bare `docker run` does.
#
# Deliberately NOT --rm: the container's log is the only diagnosis a nightly
# failure leaves behind, and --rm would take it with the container the moment
# a crashed producer stopped. `cleanup` removes it by its instance-scoped name
# instead, after saving the log.
log "starting producer ${PRODUCER_NAME}"
producer_args=(-d --name "${PRODUCER_NAME}" --network=host --ipc=host --gpus all)
# isaac#244: the published 0.0.1 image cannot read its own baked driver as the
# non-root image USER. Empty value = run as the image's own user (post-fix).
if [ -n "${PRODUCER_USER}" ]; then
  producer_args+=(--user "${PRODUCER_USER}")
fi
docker run "${producer_args[@]}" \
  -e PUBLIC_IP="${PUBLIC_IP}" \
  -e ISAAC_SIGNAL_PORT="${SIGNAL_PORT}" \
  "${PRODUCER_IMAGE}" >/dev/null

log "waiting up to ${BOOT_TIMEOUT}s for: ${READY_MARKER}"
deadline=$((SECONDS + BOOT_TIMEOUT))
ready=false
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if ! _container_running "${PRODUCER_NAME}"; then
    fail "producer container exited before the streaming server started"
    docker logs "${PRODUCER_NAME}" 2>&1 | tail -n 60 || true
    exit 1
  fi
  if _log_contains "${PRODUCER_NAME}" "${READY_MARKER}"; then
    ready=true
    break
  fi
  sleep 5
done

if [ "${ready}" != true ]; then
  fail "producer did not report '${READY_MARKER}' within ${BOOT_TIMEOUT}s"
  docker logs "${PRODUCER_NAME}" 2>&1 | tail -n 60 || true
  exit 1
fi
log "producer is streaming; handing over to the browser"

# One container is both the viewer and the browser: e2e-test is FROM runtime,
# so it carries the real dist AND Playwright/Chromium. Host network so the page
# it serves and the producer it dials are both on 127.0.0.1.
rc=0
docker run --rm \
  --name "${VIEWER_NAME}" \
  --network=host \
  -e SIGNALING_SERVER="${PUBLIC_IP}" \
  -e SIGNALING_PORT="${SIGNAL_PORT}" \
  -e SERVE_PORT="${SERVE_PORT}" \
  -e OWV_ARTIFACT_DIR=/artifacts \
  -v "${ARTIFACT_DIR}":/artifacts \
  "${VIEWER_IMAGE}" \
  bash /e2e/run-tier-b.sh || rc=$?

if [ "${rc}" -ne 0 ]; then
  fail "visual acceptance failed (exit ${rc}); producer log tail follows"
  docker logs "${PRODUCER_NAME}" 2>&1 | tail -n 60 || true
  exit "${rc}"
fi

log "PASS: a real browser rendered a real, non-black frame from a real Kit producer"
