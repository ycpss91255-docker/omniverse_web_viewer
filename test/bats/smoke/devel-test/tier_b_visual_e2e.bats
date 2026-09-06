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
  ARGV_LOG="${TMP}/docker-argv.log"
  ATT_SRC="${TMP}/staged-attestation.json"

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

  # JOB CONTROL ON for the launch, and it is not optional. POSIX says a command
  # started asynchronously (`&`) from a shell WITHOUT job control has SIGINT
  # and SIGQUIT set to IGNORE, so under bats the SIGINT case would measure
  # bash's inherited disposition rather than the driver's trap -- observed
  # here: the driver ignored the signal outright and ran to its boot timeout.
  # `set -m` gives the child its own process group and the default
  # dispositions. The kill below still targets the PID, not the group, which is
  # the case that matters: a process-group signal was never the broken one.
  set -m
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
  set +m

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

# why: Guards the EXIT STATUS of `script/ci/tier_b_visual_e2e.sh`, the Tier
# B driver. Its header says `Exit 0 = a real browser saw a real, non-black
# frame`, and the workflow's picture gate believes exactly that -- so
# exiting 0 without having asserted a picture is the one failure this script
# may never have. It could: `cleanup()` took `local rc=$?` and ended `exit
# "${rc}"` while trapped on `EXIT INT TERM`, and on a signal path `$?` is
# the last COMPLETED command (the boot-wait `sleep 5`, i.e. 0). No GPU, Kit
# or docker daemon is involved -- a stub `docker` on `PATH` answers just
# enough for the driver to reach its boot-wait loop and stay there, which is
# the state under test. The script is copied into the image at `/ci/`.

# why: The producer runs as root with `--network=host --ipc=host --gpus all`
# on the persistent GPU runner, and GHCR tags are mutable; the workflow's
# pull step asks the driver for the reference, so this covers the pull too
@test "tier_b: the producer image is pinned by digest, not by a mutable tag" {
  run bash "${DRIVER}" --print-producer-image
  assert_success
  assert_output --regexp '^ghcr\.io/.+@sha256:[0-9a-f]{64}$'
}

# why: A GitHub step timeout / job cancellation must not be readable as a
# verified picture (143)
@test "tier_b: SIGTERM exits non-zero, so a killed run cannot claim a picture" {
  run _signal_driver TERM
  assert [ "${status}" -ne 0 ]
  # 128 + SIGTERM, the shell convention the driver's trap sets explicitly.
  assert [ "${status}" -eq 143 ]
}

# why: Same for an interrupt (130)
@test "tier_b: SIGINT exits non-zero, so a killed run cannot claim a picture" {
  run _signal_driver INT
  assert [ "${status}" -ne 0 ]
  # 128 + SIGINT.
  assert [ "${status}" -eq 130 ]
}

# why: The signal handler and the EXIT handler used to be the same function,
# so its own `exit` re-entered it and `producer.log` was written twice
@test "tier_b: teardown runs exactly once on a signal path" {
  # The signal handler and the EXIT handler used to be the SAME function, so
  # its own `exit` re-entered it and teardown (including the producer.log
  # write) happened twice.
  run _signal_driver TERM
  run grep -c 'teardown: dropping' "${DRIVER_LOG}"
  assert_output "1"
}

# ---------------------------------------------------------------------------
# ATTESTATION: exit 0 must mean "a frame was seen", not "the browser step
# returned 0".
#
# Review round 8 produced five single-step, checker-green ways to make the
# tier-b job report success without a picture: truncating this driver to zero
# bytes (`: > script/ci/tier_b_visual_e2e.sh --print-x`), shadowing `bash` via
# $GITHUB_PATH, `sed -i '1a exit 0' script/ci/*.sh`, a job-level `container:`
# whose bash is a stub, and $GITHUB_ENV pointing TIER_B_PRODUCER_IMAGE at
# busybox. Every one of them ends the same way -- the acceptance spec never
# runs, so no frame is ever sampled -- and no amount of reading main.yaml can
# tell them apart from a real run.
#
# So the driver stops trusting the browser step's exit status alone and
# requires the EVIDENCE the spec writes when it actually sampled a non-black
# frame. A run that produced no attestation, or one bound to a different
# commit, is not a verified picture and must not exit 0.
#
# The stub below drives the whole happy path with no GPU, no Kit and no daemon:
# the producer "boots" (logs emit the ready marker) and the viewer "passes"
# (docker run exits 0) -- while writing nothing. That is exactly the shape of
# all five bypasses.

ATTESTATION_NAME="tier-b-attestation.json"

# A docker stub that reaches the END of the run: producer logs emit the ready
# marker, so the driver leaves its boot-wait loop and starts the viewer, whose
# `docker run` exits 0 having written no evidence.
_write_passing_docker_stub() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'sub="${1:-}"' \
    'shift || true' \
    'case "${sub}" in' \
    '  image | pull | rm | inspect | stop | kill) exit 0 ;;' \
    '  run)' \
    '    : >"${OWV_STUB_STARTED}"' \
    '    printf "%s\\n" "$*" >>"${OWV_STUB_ARGV}"' \
    '    # Standing in for the acceptance container: the evidence appears' \
    '    # DURING the run, written by the thing that saw the frame -- which' \
    '    # is the only way it appears for real. A test that pre-plants it is' \
    '    # testing the verifier against its own wishful fixture.' \
    '    for a in "$@"; do' \
    '      case "${a}" in' \
    '        */viewer:*)' \
    '          if [ -n "${OWV_STUB_ATT_SRC:-}" ] && [ -f "${OWV_STUB_ATT_SRC}" ]; then' \
    '            cp "${OWV_STUB_ATT_SRC}" "${OWV_STUB_ATT_DST}"' \
    '          fi' \
    '          ;;' \
    '      esac' \
    '    done' \
    '    echo stub-container-id' \
    '    exit 0' \
    '    ;;' \
    '  ps)' \
    '    for a in "$@"; do' \
    '      if [ "${a}" = "--filter" ]; then exit 0; fi' \
    '    done' \
    '    printf "%s\n" "${OWV_STUB_NAME}"' \
    '    exit 0' \
    '    ;;' \
    '  logs)' \
    '    printf "%s\n" "[PRODUCER] empty lit stage streaming"' \
    '    exit 0' \
    '    ;;' \
    '  *) exit 0 ;;' \
    'esac' \
    > "${STUB_BIN}/docker"
  chmod 0755 "${STUB_BIN}/docker"
}

# Run the driver to completion against the passing stub. Extra env assignments
# may be passed as KEY=VALUE arguments. Returns the driver's exit status;
# combined output lands in "${DRIVER_LOG}".
_run_driver_to_completion() {
  local rc=0
  env \
    PATH="${STUB_BIN}:${PATH}" \
    OWV_STUB_NAME="${STUB_PRODUCER}" \
    OWV_STUB_STARTED="${STARTED}" \
    OWV_STUB_ARGV="${ARGV_LOG}" \
    OWV_STUB_ATT_SRC="${ATT_SRC}" \
    OWV_STUB_ATT_DST="${ARTIFACTS}/${ATTESTATION_NAME}" \
    TIER_B_INSTANCE="${STUB_INSTANCE}" \
    TIER_B_PRODUCER_IMAGE="stub/producer:0.0.0" \
    TIER_B_VIEWER_IMAGE="stub/viewer:e2e-test" \
    TIER_B_SERVE_PORT="5399" \
    TIER_B_SIGNAL_PORT="49399" \
    TIER_B_ARTIFACT_DIR="${ARTIFACTS}" \
    TIER_B_BOOT_TIMEOUT="30" \
    "$@" \
    bash "${DRIVER}" >"${DRIVER_LOG}" 2>&1 || rc=$?
  return "${rc}"
}

# Write an attestation of the shape the spec produces on a real pass.
# _write_attestation [KEY=VALUE ...] overrides individual JSON fields.
_write_attestation() {
  local commit="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  local run_id="12345"
  local mean_luma="151.99"
  local max_luma="255"
  local bright="0.99988"
  local width="1920"
  local height="1080"
  local kv key value

  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    case "${key}" in
      commit) commit="${value}" ;;
      run_id) run_id="${value}" ;;
      meanLuma) mean_luma="${value}" ;;
      maxLuma) max_luma="${value}" ;;
      brightFraction) bright="${value}" ;;
      width) width="${value}" ;;
      height) height="${value}" ;;
    esac
  done

  mkdir -p "${ARTIFACTS}"
  printf '%s\n' \
    '{' \
    "  \"commit\": \"${commit}\"," \
    "  \"run_id\": \"${run_id}\"," \
    "  \"width\": ${width}," \
    "  \"height\": ${height}," \
    "  \"meanLuma\": ${mean_luma}," \
    "  \"maxLuma\": ${max_luma}," \
    "  \"brightFraction\": ${bright}" \
    '}' \
    > "${ATT_SRC}"
}

@test "tier_b: a browser step that exits 0 without evidence is not a picture" {
  _write_passing_docker_stub

  run _run_driver_to_completion
  [ "${status}" -ne 0 ]
  grep -qiE 'attestation|evidence' "${DRIVER_LOG}"
}

@test "tier_b: an attestation naming a different commit is rejected" {
  _write_passing_docker_stub
  _write_attestation commit=1111111111111111111111111111111111111111

  run _run_driver_to_completion \
    GITHUB_SHA=2222222222222222222222222222222222222222
  [ "${status}" -ne 0 ]
  grep -qiE 'commit' "${DRIVER_LOG}"
}

@test "tier_b: an attestation naming a different run is rejected" {
  _write_passing_docker_stub
  _write_attestation run_id=111

  run _run_driver_to_completion GITHUB_RUN_ID=222
  [ "${status}" -ne 0 ]
  grep -qiE 'run' "${DRIVER_LOG}"
}

@test "tier_b: a black frame in the attestation is rejected" {
  _write_passing_docker_stub
  _write_attestation meanLuma=0 maxLuma=0 brightFraction=0

  run _run_driver_to_completion
  [ "${status}" -ne 0 ]
}

@test "tier_b: a matching attestation with a real frame passes" {
  _write_passing_docker_stub
  _write_attestation commit=abc0000000000000000000000000000000000abc run_id=777

  run _run_driver_to_completion \
    GITHUB_SHA=abc0000000000000000000000000000000000abc \
    GITHUB_RUN_ID=777
  [ "${status}" -eq 0 ]
}

# The bug this case exists for: the acceptance spec reads GITHUB_SHA and
# GITHUB_RUN_ID from ITS OWN process environment, and it runs inside a
# container. The driver runs on the runner, where both are set. If they are
# not plumbed across that boundary the spec writes commit "" -- and the
# verifier, comparing against the runner's real SHA, refuses every single
# run. Fail-closed, so the invariant held; but the release path would have
# been dead on arrival, and no amount of verifier testing would have shown it,
# because the verifier was only ever fed fixtures written the way the author
# wished the producer wrote them.
#
# So this asserts the PLUMBING, not the parsing: the two flags are on the
# command line the driver actually emits.
@test "tier_b: the acceptance container is given the commit and run it must attest to" {
  _write_passing_docker_stub
  _write_attestation commit=abc0000000000000000000000000000000000abc run_id=777

  run _run_driver_to_completion \
    GITHUB_SHA=abc0000000000000000000000000000000000abc \
    GITHUB_RUN_ID=777
  [ "${status}" -eq 0 ]

  # The viewer is the last container the driver starts.
  grep -q -- '-e GITHUB_SHA=abc0000000000000000000000000000000000abc' "${ARGV_LOG}"
  grep -q -- '-e GITHUB_RUN_ID=777' "${ARGV_LOG}"
}

# An attestation planted before the run is not this run's evidence.
@test "tier_b: an attestation left behind before the run is discarded" {
  _write_passing_docker_stub
  _write_attestation
  # Planted directly in the artifact dir, as an earlier step in the job could:
  # the workflow's pre-clean runs before checkout and the driver only mkdir -p's
  # this directory. Staging it (the stub path) is how a REAL run delivers it.
  cp "${ATT_SRC}" "${ARTIFACTS}/${ATTESTATION_NAME}"
  # ...and the acceptance container writes nothing, which is the whole point:
  # the planted file is the ONLY evidence, and it is not this run's.
  rm -f "${ATT_SRC}"

  run _run_driver_to_completion
  [ "${status}" -ne 0 ]
}
