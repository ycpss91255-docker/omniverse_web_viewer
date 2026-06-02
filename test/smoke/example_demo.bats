#!/usr/bin/env bats
#
# Contract smoke for the embeddable example (examples/embedded-site-demo).
# The full example build -- npm install / eslint / vite build / serve-200 --
# runs in the Dockerfile `example` stage. Here we guard the source-level
# contract and run the pure unit tests (no node_modules needed: the tested
# module imports nothing external).

EXAMPLE_DIR="/examples/embedded-site-demo"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "example: key files exist" {
  assert_file_exists "${EXAMPLE_DIR}/index.html"
  assert_file_exists "${EXAMPLE_DIR}/package.json"
  assert_file_exists "${EXAMPLE_DIR}/src/main.ts"
  assert_file_exists "${EXAMPLE_DIR}/src/buildStreamConfig.js"
  assert_file_exists "${EXAMPLE_DIR}/src/buildStreamConfig.test.js"
}

@test "example: only runtime dependency is the streaming library" {
  run node -e 'const d=require("'"${EXAMPLE_DIR}"'/package.json").dependencies||{};const k=Object.keys(d);process.exit(k.length===1&&k[0]==="@nvidia/omniverse-webrtc-streaming-library"?0:1)'
  assert_success
}

@test "example: streamTarget.json carries both sentinels" {
  run grep -F "__OWV_SERVER__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
  run grep -F "__OWV_PORT__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
}

@test "example: buildStreamConfig unit tests pass (node --test)" {
  run bash -c "cd '${EXAMPLE_DIR}' && node --test"
  assert_success
}
