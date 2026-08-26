#!/usr/bin/env bats
#
# Regression lock for script/ci/tier_b_visual_e2e.sh's EXIT STATUS on a signal.
#
# That script's own header says `Exit 0 = a real browser saw a real, non-black
# frame`, and .github/workflows/main.yaml hangs the picture gate off exactly
# that: call-release and publish-image require the Tier B job to have
# succeeded. So the one thing the driver may never do is exit 0 without having
# asserted a picture.
#
# It used to. `cleanup()` opened with `local rc=$?` and closed with
# `exit "${rc}"` while trapped on EXIT INT TERM. On a signal path `$?` is the
# last COMPLETED command's status -- the boot-wait loop's `sleep 5`, i.e. 0 --
# so signalling the script's pid alone (a GitHub step timeout, a job
# cancellation, a `kill` by hand) made it exit 0 and report the picture
# verified having asserted nothing. The same function being both the signal
# handler and the EXIT handler also re-entered it through its own `exit`, so
# teardown ran twice and producer.log was written twice.
#
# There is no GPU, no Kit and no docker daemon here, and there does not need to
# be: the question is what the driver's exit status is when it is signalled
# mid-run, which a stub `docker` on PATH is enough to ask. The stub answers
# just enough for the driver to reach its boot-wait loop and stay there.
#
# The script is copied into the image at /ci/ by the `devel-test` stage.

DRIVER="/ci/tier_b_visual_e2e.sh"

# Instance scope for the stubbed run. The driver derives every container name
# from it, and its teardown refuses any name outside the owv-tierb-* prefix.
STUB_INSTANCE="batsstub"
STUB_PRODUCER="owv-tierb-${STUB_INSTANCE}-producer"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  TMP="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  STUB_BIN="${TMP}/bin"
  ARTIFACTS="${TMP}/artifacts"
  DRIVER_LOG="${TMP}/driver.log"
  STARTED="${TMP}/producer-started"

  mkdir -p "${STUB_BIN}" "${ARTIFACTS}"
  _write_docker_stub
}

# A `docker` that never talks to a daemon. It answers the handful of
# subcommands the driver reaches before it starts waiting for the producer's
# scene-ready marker, and deliberately never emits that marker -- so the driver
# sits in its boot-wait loop until it is signalled, which is the state under
# test.
_write_docker_stub() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'sub="${1:-}"' \
    'shift || true' \
    'case "${sub}" in' \
    '  image | pull | rm | inspect) exit 0 ;;' \
    '  run)' \
    '    : >"${OWV_STUB_STARTED}"' \
    '    echo stub-container-id' \
    '    exit 0' \
    '    ;;' \
    '  ps)' \
    '    # The orphan reaper passes --filter; answer it with an empty list so' \
    '    # nothing is reaped. Every other ps is an existence/liveness check.' \
    '    for a in "$@"; do' \
    '      if [ "${a}" = "--filter" ]; then exit 0; fi' \
    '    done' \
    '    printf "%s\n" "${OWV_STUB_NAME}"' \
    '    exit 0' \
    '    ;;' \
    '  logs)' \
    '    # Anything BUT the ready marker, so the driver keeps waiting.' \
    '    printf "stub producer: still booting\n"' \
    '    exit 0' \
    '    ;;' \
    '  *) exit 0 ;;' \
    'esac' \
    > "${STUB_BIN}/docker"
  chmod 0755 "${STUB_BIN}/docker"
}

# _signal_driver <signal> -- run the driver against the stub, wait until it is
# inside the boot-wait loop, send <signal>, and return the driver's own exit
# status. Combined output lands in "${DRIVER_LOG}".
_signal_driver() {
  local signal="$1" rc=0 pid waited=0

  env \
    PATH="${STUB_BIN}:${PATH}" \
    OWV_STUB_NAME="${STUB_PRODUCER}" \
    OWV_STUB_STARTED="${STARTED}" \
    TIER_B_INSTANCE="${STUB_INSTANCE}" \
    TIER_B_PRODUCER_IMAGE="stub/producer:0.0.0" \
    TIER_B_VIEWER_IMAGE="stub/viewer:e2e-test" \
    TIER_B_SERVE_PORT="5399" \
    TIER_B_SIGNAL_PORT="49399" \
    TIER_B_ARTIFACT_DIR="${ARTIFACTS}" \
    TIER_B_BOOT_TIMEOUT="120" \
    bash "${DRIVER}" >"${DRIVER_LOG}" 2>&1 &
  pid="$!"

  # The stub touches this the moment the driver starts the producer, which is
  # immediately before the boot-wait loop.
  while [ ! -f "${STARTED}" ] && [ "${waited}" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  kill "-${signal}" "${pid}" 2>/dev/null || true
  wait "${pid}" || rc=$?
  return "${rc}"
}

# The producer runs as root with --network=host --ipc=host --gpus all on a
# PERSISTENT self-hosted GPU runner, and GHCR tags are mutable -- the workflow
# says so itself, and pins its busybox by digest for the weaker case. isaac#244
# is an open defect in this image, so a re-push under the same tag is likely.
# The workflow's pull step asks this script for the reference, so this one
# assertion covers both the run and the pull.
@test "tier_b: the producer image is pinned by digest, not by a mutable tag" {
  run bash "${DRIVER}" --print-producer-image
  assert_success
  assert_output --regexp '^ghcr\.io/.+@sha256:[0-9a-f]{64}$'
}

@test "tier_b: SIGTERM exits non-zero, so a killed run cannot claim a picture" {
  run _signal_driver TERM
  assert [ "${status}" -ne 0 ]
  # 128 + SIGTERM, the shell convention the driver's trap sets explicitly.
  assert [ "${status}" -eq 143 ]
}

@test "tier_b: SIGINT exits non-zero, so a killed run cannot claim a picture" {
  run _signal_driver INT
  assert [ "${status}" -ne 0 ]
  # 128 + SIGINT.
  assert [ "${status}" -eq 130 ]
}

@test "tier_b: teardown runs exactly once on a signal path" {
  # The signal handler and the EXIT handler used to be the SAME function, so
  # its own `exit` re-entered it and teardown (including the producer.log
  # write) happened twice.
  run _signal_driver TERM
  run grep -c 'teardown: dropping' "${DRIVER_LOG}"
  assert_output "1"
}
