#!/usr/bin/env bats
#
# Contract smoke for the embeddable example (examples/embedded-site-demo).
# The full build -- workspace install / eslint / vite build / serve-200 -- runs
# in the Dockerfile `example` stage. Here we guard the source-level contract and
# run the pure unit tests (no node_modules needed: the tested module imports
# nothing external).

EXAMPLE_DIR="/examples/embedded-site-demo"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "example: key files exist" {
  assert_file_exists "${EXAMPLE_DIR}/index.html"
  assert_file_exists "${EXAMPLE_DIR}/package.json"
  assert_file_exists "${EXAMPLE_DIR}/src/main.ts"
  assert_file_exists "${EXAMPLE_DIR}/src/resolveTarget.js"
  assert_file_exists "${EXAMPLE_DIR}/test/resolveTarget.test.js"
}

@test "example: depends on stream-core + the streaming library only" {
  run node -e 'const d=require("'"${EXAMPLE_DIR}"'/package.json").dependencies||{};const k=Object.keys(d).sort();process.exit(k.length===2&&k[0]==="@nvidia/omniverse-webrtc-streaming-library"&&k[1]==="stream-core"?0:1)'
  assert_success
}

@test "example: imports the factory from stream-core (local copy deleted)" {
  run grep -F "from 'stream-core'" "${EXAMPLE_DIR}/src/main.ts"
  assert_success
  run test -f "${EXAMPLE_DIR}/src/buildStreamConfig.js"
  assert_failure
}

@test "example: streamTarget.json carries all three sentinels" {
  run grep -F "__OWV_SERVER__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
  run grep -F "__OWV_PORT__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
  run grep -F "__OWV_MEDIA_PORT__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
}

@test "example: resolveTarget unit tests pass (node --test)" {
  run bash -c "cd '${EXAMPLE_DIR}' && node --test 'test/*.test.js'"
  assert_success
}
