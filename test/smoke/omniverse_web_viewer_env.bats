#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the `devel` image built
# from this repo's Dockerfile, via the `test` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, assert_pip_pkg, ...) to keep
# assertions terse. Add one assertion per meaningful installation
# artifact.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
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

@test "built JS contains OWV placeholders" {
  run grep -r "__OWV_SERVER__" /app/dist/assets/
  assert_success
  run grep -r "__OWV_PORT__" /app/dist/assets/
  assert_success
  run grep -r "__OWV_UI_MODE__" /app/dist/assets/
  assert_success
  run grep -r "__OWV_AUTOLAUNCH__" /app/dist/assets/
  assert_success
}

@test "entrypoint substitutes viewer placeholders with defaults" {
  # Runs the entrypoint with a no-op command; it rewrites /app/dist in
  # place. Must come after the placeholder-presence test above (bats runs
  # tests in file order).
  run /entrypoint.sh true
  assert_success
  run grep -r "__OWV_UI_MODE__" /app/dist/assets/
  assert_failure
  run grep -r "__OWV_AUTOLAUNCH__" /app/dist/assets/
  assert_failure
  # Default ui_mode is usd-viewer.
  run grep -r "usd-viewer" /app/dist/assets/
  assert_success
}
