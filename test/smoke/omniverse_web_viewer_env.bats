#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the `devel` image built
# from this repo's Dockerfile, via the `test` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, assert_pip_pkg, ...) to keep
# assertions terse.
#
# Config-pipeline model (#17): the build injects four sentinels
# (__OWV_SERVER__ / "__OWV_PORT__" / __OWV_UI_MODE__ /
# "__OWV_AUTOLAUNCH__") into the bundle, then preserves each
# sentinel-bearing chunk as a pristine *.js.tmpl. The entrypoint
# re-renders *.js.tmpl -> *.js on EVERY boot (idempotent, de-one-shot),
# after validating every operator-supplied value (a bad value fails the
# container fast instead of baking a broken bundle).
#
# Discriminator note: ui_mode / auto_launch string values ("stream-only"
# etc.) also appear as source literals in App.tsx, so grepping for them
# does not prove substitution. The render path is therefore proven with
# DISTINCTIVE server IPs / ports that cannot appear except via the
# sentinel substitution; ui_mode / auto_launch are covered by the
# validation (reject) tests instead.

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

@test "build preserves sentinel-bearing JS templates" {
  # The pristine *.js.tmpl retain all four sentinels; the entrypoint
  # renders them on every boot, so the templates are the source of truth.
  run grep -rF "__OWV_SERVER__" /app/dist/assets/ --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_PORT__" /app/dist/assets/ --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_UI_MODE__" /app/dist/assets/ --include="*.js.tmpl"
  assert_success
  run grep -rF "__OWV_AUTOLAUNCH__" /app/dist/assets/ --include="*.js.tmpl"
  assert_success
}

@test "entrypoint renders defaults into *.js and clears sentinels" {
  run /entrypoint.sh true
  assert_success
  # Sentinels are gone from the rendered *.js (the *.js.tmpl keep them).
  run grep -rF "__OWV_SERVER__" /app/dist/assets/ --include="*.js"
  assert_failure
  run grep -rF "__OWV_PORT__" /app/dist/assets/ --include="*.js"
  assert_failure
  run grep -rF "__OWV_UI_MODE__" /app/dist/assets/ --include="*.js"
  assert_failure
  run grep -rF "__OWV_AUTOLAUNCH__" /app/dist/assets/ --include="*.js"
  assert_failure
  # Defaults applied: server 127.0.0.1, port 49100, ui_mode usd-viewer.
  run grep -rF "127.0.0.1" /app/dist/assets/ --include="*.js"
  assert_success
  run grep -rF "49100" /app/dist/assets/ --include="*.js"
  assert_success
  run grep -rF "usd-viewer" /app/dist/assets/ --include="*.js"
  assert_success
}

@test "entrypoint applies SIGNALING_SERVER env override" {
  SIGNALING_SERVER="10.11.12.13" run /entrypoint.sh true
  assert_success
  run grep -rF "10.11.12.13" /app/dist/assets/ --include="*.js"
  assert_success
}

@test "entrypoint re-renders on every run (de-one-shot, #17)" {
  # First render with one server, then a different one. The second value
  # must win AND the first must be gone -- proves it is not one-shot.
  SIGNALING_SERVER="10.20.20.20" run /entrypoint.sh true
  assert_success
  run grep -rF "10.20.20.20" /app/dist/assets/ --include="*.js"
  assert_success
  SIGNALING_SERVER="10.30.30.30" run /entrypoint.sh true
  assert_success
  run grep -rF "10.30.30.30" /app/dist/assets/ --include="*.js"
  assert_success
  run grep -rF "10.20.20.20" /app/dist/assets/ --include="*.js"
  assert_failure
}

@test "host.yaml public_ip takes precedence over env" {
  printf 'network:\n  public_ip: "10.99.99.99"\n' \
    | sudo tee /etc/host.yaml >/dev/null
  SIGNALING_SERVER="10.11.12.13" run /entrypoint.sh true
  assert_success
  run grep -rF "10.99.99.99" /app/dist/assets/ --include="*.js"
  assert_success
  run grep -rF "10.11.12.13" /app/dist/assets/ --include="*.js"
  assert_failure
}

@test "host.yaml inline comment is stripped from the value" {
  printf 'network:\n  public_ip: "10.88.88.88"  # LEAKCOMMENT\n' \
    | sudo tee /etc/host.yaml >/dev/null
  run /entrypoint.sh true
  assert_success
  run grep -rF "10.88.88.88" /app/dist/assets/ --include="*.js"
  assert_success
  run grep -rF "LEAKCOMMENT" /app/dist/assets/ --include="*.js"
  assert_failure
}

@test "non-numeric SIGNALING_PORT is rejected" {
  SIGNALING_PORT="80x" run /entrypoint.sh true
  assert_failure
}

@test "invalid VIEWER_UI_MODE is rejected" {
  VIEWER_UI_MODE="bogus" run /entrypoint.sh true
  assert_failure
}

@test "SIGNALING_SERVER with shell/sed metacharacters is rejected" {
  SIGNALING_SERVER="a;rm -rf /|b" run /entrypoint.sh true
  assert_failure
}
