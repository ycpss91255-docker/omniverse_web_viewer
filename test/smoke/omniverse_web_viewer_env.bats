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
  # All four sentinels are gone after substitution.
  run grep -r "__OWV_SERVER__" /app/dist/assets/
  assert_failure
  run grep -r "__OWV_PORT__" /app/dist/assets/
  assert_failure
  run grep -r "__OWV_UI_MODE__" /app/dist/assets/
  assert_failure
  run grep -r "__OWV_AUTOLAUNCH__" /app/dist/assets/
  assert_failure
  # Defaults are applied: server 127.0.0.1, port 49100, ui_mode usd-viewer.
  # (Plain value greps — the minified bundle may quote object keys, so we do
  # not anchor on the property name. The autoLaunch fold-regression is already
  # guarded by the placeholder-presence test above.)
  run grep -rF "127.0.0.1" /app/dist/assets/
  assert_success
  run grep -rF "49100" /app/dist/assets/
  assert_success
  run grep -rF "usd-viewer" /app/dist/assets/
  assert_success
}

# NOTE: env-override (VIEWER_* without host.yaml) and host.yaml-precedence
# coverage is deferred to the entrypoint redesign (#17): the current
# entrypoint mutates /app/dist in place (one-shot), so a second run with
# different config does nothing within the same image, which makes those
# paths untestable here. They become the red guards once #17 makes the
# substitution re-runnable (template-render).
