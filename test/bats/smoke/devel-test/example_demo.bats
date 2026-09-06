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

# why: index.html / package.json / main.ts / resolveTarget.js + its test
@test "example: key files exist" {
  assert_file_exists "${EXAMPLE_DIR}/index.html"
  assert_file_exists "${EXAMPLE_DIR}/package.json"
  assert_file_exists "${EXAMPLE_DIR}/src/main.ts"
  assert_file_exists "${EXAMPLE_DIR}/src/resolveTarget.js"
  assert_file_exists "${EXAMPLE_DIR}/test/resolveTarget.test.js"
}

# why: Exactly 2 runtime deps
@test "example: depends on stream-core + the streaming library only" {
  run node -e 'const d=require("'"${EXAMPLE_DIR}"'/package.json").dependencies||{};const k=Object.keys(d).sort();process.exit(k.length===2&&k[0]==="@nvidia/omniverse-webrtc-streaming-library"&&k[1]==="stream-core"?0:1)'
  assert_success
}

# why: No duplicate `buildStreamConfig` (S3 dedup)
@test "example: imports the factory from stream-core (local copy deleted)" {
  run grep -F "from 'stream-core'" "${EXAMPLE_DIR}/src/main.ts"
  assert_success
  run test -f "${EXAMPLE_DIR}/src/buildStreamConfig.js"
  assert_failure
}

# why: server/port/media sentinels present
@test "example: streamTarget.json carries all three sentinels" {
  run grep -F "__OWV_SERVER__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
  run grep -F "__OWV_PORT__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
  run grep -F "__OWV_MEDIA_PORT__" "${EXAMPLE_DIR}/src/streamTarget.json"
  assert_success
}

# why: Runs the example's own glue tests in-image
@test "example: resolveTarget unit tests pass (node --test)" {
  run bash -c "cd '${EXAMPLE_DIR}' && node --test 'test/*.test.js'"
  assert_success
}

# #63 IS A PROPERTY OF THE INTERFACE, NOT OF ONE CONSUMER.
#
# `onStart` fires when a connect ATTEMPT begins and re-fires on every
# session-start retry -- observed five times against a producer that was never
# there. Mapping it onto `streaming <server>:<port>` therefore reports a live
# stream with nothing connected. That was fixed in apps/stream-only on
# 2026-08-14; this demo, the other consumer of the same stream-core interface,
# kept the defect for three weeks and was edited again in between without
# anyone noticing, because nothing asserted it.
#
# The assertion is over the SOURCE and not over a rendered page because the
# demo has no browser suite: the trade is admitted rather than skipped.
# why: `onStart` fires when an ATTEMPT begins and re-fires on every
# session-start retry, so `streaming <server>:<port>` reports a live stream
# with nothing connected. Fixed in `apps/stream-only` on 2026-08-14; this
# second consumer of the same stream-core interface kept the defect for
# three weeks and was edited again in between, because nothing asserted it.
# Over the source, not a rendered page: the demo has no browser suite, and
# the trade is admitted rather than skipped
@test "example: onStart does not claim the stream is live (#63)" {
  run grep -nE "onStart:.*streaming " "${EXAMPLE_DIR}/src/main.ts"
  assert_failure
}

# The other half: a failed connect must not be rendered with String(), which
# the library's plain-object rejections turn into "[object Object]" -- the
# reason discarded on the one path where the user needs it.
# why: The library rejects with plain objects
# (`throw{action,status,info:"..."}`), so `String(e)` is `[object Object]`
# and the only actionable sentence is discarded. Asserts
# `describeStreamError` is used instead
@test "example: a failed connect is not rendered with String()" {
  run grep -nE 'connection failed:.*\$\{String\(' "${EXAMPLE_DIR}/src/main.ts"
  assert_failure
  run grep -F "describeStreamError" "${EXAMPLE_DIR}/src/main.ts"
  assert_success
}
