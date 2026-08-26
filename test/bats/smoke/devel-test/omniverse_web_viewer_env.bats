#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the `devel` image built
# from this repo's Dockerfile, via the `devel-test` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, ...) to keep assertions terse.
#
# Config-pipeline model (S5): VIEWER_UI_MODE is an APP SELECTOR (D7). The
# entrypoint serves /app/${VIEWER_UI_MODE}/dist and renders ONLY that dir's
# *.js.tmpl on every boot, after validating every operator value. Each app's
# build preserves its sentinel-bearing chunks as pristine *.js.tmpl:
#   - usd-viewer    carries __OWV_SERVER__ + "__OWV_PORT__"        (server/port)
#   - stream-only   carries those PLUS "__OWV_MEDIA_PORT__"        (+media, D1)
# The render path is proven with DISTINCTIVE server IPs / ports that cannot
# appear except via sentinel substitution. The render is idempotent: it always
# re-renders from the pristine *.js.tmpl, never from a previously-rendered *.js.
#
# devel-test is FROM devel, so BOTH /app/usd-viewer/dist and
# /app/stream-only/dist exist here for the bats to exercise.

USD_ASSETS="/app/usd-viewer/dist/assets"
STREAM_ASSETS="/app/stream-only/dist/assets"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

teardown() {
  # Several tests mount config via /etc/host.yaml; always clear it so a
  # later test sees a clean (env/default-only) state regardless of order.
  sudo rm -f /etc/host.yaml 2>/dev/null || true
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}

@test "SIGNALING_SERVER env defaults to 127.0.0.1" {
  assert [ "${SIGNALING_SERVER}" = "127.0.0.1" ]
}

@test "SIGNALING_PORT env defaults to 49100" {
  assert [ "${SIGNALING_PORT}" = "49100" ]
}

@test "SERVE_PORT env defaults to 5173" {
  assert [ "${SERVE_PORT}" = "5173" ]
}

@test "VIEWER_UI_MODE env defaults to usd-viewer" {
  assert [ "${VIEWER_UI_MODE}" = "usd-viewer" ]
}

@test "both app dist dirs exist (devel has both modes)" {
  assert_dir_exists "${USD_ASSETS}"
  assert_dir_exists "${STREAM_ASSETS}"
}

@test "usd-viewer build preserves server/port templates, no media sentinel" {
  run grep -rF "__OWV_SERVER__" "${USD_ASSETS}/" --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_PORT__" "${USD_ASSETS}/" --include="*.js.tmpl"
  assert_success
  # usd-viewer keeps upstream native SDP media negotiation -- no media sentinel.
  run grep -rF "__OWV_MEDIA_PORT__" "${USD_ASSETS}/" --include="*.js.tmpl"
  assert_failure
}

@test "stream-only build preserves all three sentinels in templates" {
  run grep -rF "__OWV_SERVER__" "${STREAM_ASSETS}/" --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_PORT__" "${STREAM_ASSETS}/" --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_MEDIA_PORT__" "${STREAM_ASSETS}/" --include="*.js.tmpl"
  assert_success
}

@test "default mode (usd-viewer) renders defaults + clears sentinels" {
  run /entrypoint.sh true
  assert_success
  # Sentinels gone from rendered *.js (the *.js.tmpl keep them).
  run grep -rF "__OWV_SERVER__" "${USD_ASSETS}/" --include="*.js"
  assert_failure
  run grep -rF "__OWV_PORT__" "${USD_ASSETS}/" --include="*.js"
  assert_failure
  # Defaults applied: server 127.0.0.1, port 49100.
  run grep -rF "127.0.0.1" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "49100" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

@test "default mode renders ONLY the usd-viewer dir, not stream-only" {
  # Distinctive server that must only appear in the active (usd-viewer) dir.
  SIGNALING_SERVER="10.1.1.1" run /entrypoint.sh true
  assert_success
  run grep -rF "10.1.1.1" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.1.1.1" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
}

@test "usd-viewer applies SIGNALING_SERVER env override" {
  SIGNALING_SERVER="10.11.12.13" run /entrypoint.sh true
  assert_success
  run grep -rF "10.11.12.13" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

# The server override above had a port-shaped sibling missing: every render
# assertion in this file, and the tier-1 e2e, used 49100 -- which is the baked
# default (Dockerfile ENV, entrypoint fallback, overlay/stream.config.json), so
# none of them could tell a rendered port from a fallback. 49277 can only get
# into the bundle through the sed.
@test "usd-viewer applies SIGNALING_PORT env override" {
  SIGNALING_PORT="49277" run /entrypoint.sh true
  assert_success
  run grep -rF "49277" "${USD_ASSETS}/" --include="*.js"
  assert_success
}

@test "VIEWER_UI_MODE=stream-only renders the stream-only dir" {
  VIEWER_UI_MODE="stream-only" SIGNALING_SERVER="10.2.2.2" run /entrypoint.sh true
  assert_success
  run grep -rF "10.2.2.2" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
  # The active dir's sentinels are cleared.
  run grep -rF "__OWV_SERVER__" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
}

@test "stream-only unset MEDIA_PORT renders literal null (negotiate, D1)" {
  VIEWER_UI_MODE="stream-only" run /entrypoint.sh true
  assert_success
  # Sentinel is gone; the omitted media port becomes the literal null.
  run grep -rF "__OWV_MEDIA_PORT__" "${STREAM_ASSETS}/" --include="*.js"
  assert_failure
  # The rendered mediaPort value is the literal null (JSON value, not sentinel).
  run bash -c "grep -rhoE 'mediaPort\"?: *null' ${STREAM_ASSETS}/*.js"
  assert_success
}

@test "stream-only MEDIA_PORT=47998 pins the media port" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="47998" run /entrypoint.sh true
  assert_success
  run grep -rF "47998" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
}

@test "re-render is idempotent with changed values (de-one-shot, #17)" {
  # First render with one server, then a different one. The second value
  # must win AND the first must be gone -- proves it re-renders from the
  # pristine template, not the previously-rendered *.js.
  SIGNALING_SERVER="10.20.20.20" run /entrypoint.sh true
  assert_success
  run grep -rF "10.20.20.20" "${USD_ASSETS}/" --include="*.js"
  assert_success
  SIGNALING_SERVER="10.30.30.30" run /entrypoint.sh true
  assert_success
  run grep -rF "10.30.30.30" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.20.20.20" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml public_ip takes precedence over env" {
  printf 'network:\n  public_ip: "10.99.99.99"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.11.12.13" run /entrypoint.sh true
  assert_success
  run grep -rF "10.99.99.99" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.11.12.13" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml inline comment is stripped from the value" {
  printf 'network:\n  public_ip: "10.88.88.88"  # LEAKCOMMENT\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_success
  run grep -rF "10.88.88.88" "${USD_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "LEAKCOMMENT" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "host.yaml viewer.ui_mode selects the served app" {
  printf 'viewer:\n  ui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.3.3.3" run /entrypoint.sh true
  assert_success
  run grep -rF "10.3.3.3" "${STREAM_ASSETS}/" --include="*.js"
  assert_success
  run grep -rF "10.3.3.3" "${USD_ASSETS}/" --include="*.js"
  assert_failure
}

@test "entrypoint exports the resolved VIEWER_UI_MODE for the CMD" {
  # The CMD reads ${VIEWER_UI_MODE}; the entrypoint must export the
  # host.yaml/env-resolved value before exec, so a child sees it.
  printf 'viewer:\n  ui_mode: "stream-only"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh sh -c 'printf "%s" "${VIEWER_UI_MODE}"'
  assert_success
  assert [ "${output}" = "stream-only" ]
}

@test "non-numeric SIGNALING_PORT is rejected" {
  SIGNALING_PORT="80x" run /entrypoint.sh true
  assert_failure
}

# The port sed replaces the QUOTED sentinel, so the value reaches the bundle as
# a bare numeric token: `049100` renders `signalingPort:049100`, which is a
# SyntaxError in an ES module (strict mode). The chunk then fails to parse and
# the viewer is a black page -- from a container that started successfully and
# answers HTTP 200, which is all the runtime smoke ever asked.
@test "SIGNALING_PORT with a leading zero is rejected" {
  SIGNALING_PORT="049100" run /entrypoint.sh true
  assert_failure
}

@test "out-of-range SIGNALING_PORT is rejected" {
  SIGNALING_PORT="99999" run /entrypoint.sh true
  assert_failure
}

@test "MEDIA_PORT with a leading zero is rejected" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="047998" run /entrypoint.sh true
  assert_failure
}

@test "out-of-range SERVE_PORT is rejected" {
  SERVE_PORT="0" run /entrypoint.sh true
  assert_failure
}

@test "invalid VIEWER_UI_MODE is rejected" {
  VIEWER_UI_MODE="bogus" run /entrypoint.sh true
  assert_failure
}

@test "non-numeric MEDIA_PORT is rejected" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="80x" run /entrypoint.sh true
  assert_failure
}

@test "out-of-range MEDIA_PORT is rejected" {
  VIEWER_UI_MODE="stream-only" MEDIA_PORT="70000" run /entrypoint.sh true
  assert_failure
}

@test "SIGNALING_SERVER with shell/sed metacharacters is rejected" {
  SIGNALING_SERVER="a;rm -rf /|b" run /entrypoint.sh true
  assert_failure
}
