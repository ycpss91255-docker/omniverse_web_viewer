#!/usr/bin/env bats
#
# coverage_path_spec.bats -- `--coverage-path`: one named spec under kcov,
# through script/test/test.sh and _run_coverage_path in
# script/test/drivers/bats.sh.
#
# NOTE: these tests confine PATH to MOCK_DIR *after* sourcing test.sh so
# the mocked binaries resolve instead of the real ones.
#
# why: the mode writes no coverage figure and does not depend on the shard
# partition; the cases below pin both, and what it refuses.

setup() {
  export LOG_FORMAT=text
  # A caller's exported work dir is not this test's (base#1420).
  unset COVERAGE_LOCAL_WORKDIR
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  local _cmd
  # sha256sum + cut back the name derivations (_compute_test_tools_hash /
  # _compute_compose_project_name); without them a PATH-confined test would
  # exercise their fail-loud guard instead of the behaviour under test.
  # timeout wraps the compose run of the suite (base#1413), so a test that
  # reaches that call needs the real one beside the mocked docker.
  for _cmd in grep date cat printf sha256sum cut timeout; do
    local _path
    _path="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_path}" "${MOCK_DIR}/${_cmd}"
  done
}

teardown() {
  cleanup_mock_dir
}

# _kcov_slice_mock <log>
#   A kcov stand-in for the sliced shape (base#1414): it logs its argv one
#   line per call and leaves the report a real kcov would, so a driver that
#   refuses a slice with no report is not refused by the mock. `--merge`
#   is logged the same way and writes the merged report.
_kcov_slice_mock() {
  local _log="${1}"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    if [ "${1}" = "--merge" ]; then
      mkdir -p "${2}/kcov-merged"
      printf "<coverage/>\n" > "${2}/kcov-merged/cobertura.xml"
      exit 0
    fi
    _out=""
    while [ $# -gt 0 ]; do
      case "${1}" in
        -*) shift ;;
        *)  _out="${1}"; break ;;
      esac
    done
    mkdir -p "${_out}/kcov-merged"
    printf "<coverage/>\n" > "${_out}/kcov-merged/cobertura.xml"
    exit 0'
}

# ════════════════════════════════════════════════════════════════════
# --coverage-path: ONE spec under kcov instrumentation
#
# The kcov-only failure class ("this spec is red under kcov and green
# without it") had no inner loop: the only instrumented entries were the
# whole suite and a whole shard, 8-12 minutes each, and --bats-path
# refuses --coverage because it is the fast NO-kcov loop. --coverage-path
# is the third mode: kcov wrapping exactly one named spec.
#
# Two properties carry the whole design and are asserted below rather
# than described:
#
#   1. It produces NO coverage figure. The report goes to a throwaway
#      directory inside the container and is deleted, so nothing this
#      mode runs can reach the cobertura/timings artifacts the
#      coverage-gate merges -- a one-spec run must never be able to feed
#      the gate a number.
#   2. It is independent of the shard partition. The spec is named
#      directly, so neither the greedy-LPT bin-packing nor the recorded
#      weights file decides what runs -- the local partition and CI's
#      differ (locally there is no weights file to restore), and
#      "run THIS spec" has to mean the same thing in both.
# ════════════════════════════════════════════════════════════════════

# why: The gate's artifacts stay untouched -- no figure can be fabricated
# from one spec
@test "_run_coverage_path: writes nothing into the checkout's coverage/ (#887)" {
  # The gate reads coverage/cobertura.xml + coverage/timings.tsv from the
  # mounted checkout. A single-spec run that dropped either there would
  # hand the merge a partial figure (or reweight the next partition off
  # one spec), so the checkout's coverage/ must come out untouched.
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    _out=""
    for _a in "$@"; do
      case "${_a}" in --*) continue ;; esac
      _out="${_a}"; break
    done
    mkdir -p "${_out}"
    : > "${_out}/cobertura.xml"
    : > "${_out}/index.html"
    exit 0'

  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/coverage" "${REPO_ROOT}/test/bats/unit"
    : > "${REPO_ROOT}/coverage/sentinel"
    : > "${REPO_ROOT}/test/bats/unit/one_spec.bats"
    source /source/script/test/drivers/bats.sh
    _run_coverage_path test/bats/unit/one_spec.bats >/dev/null
    ls -A "${REPO_ROOT}/coverage"
  '
  assert_success
  assert_output "sentinel"
}

# why: Report lands in container-local scratch and is deleted
@test "_run_coverage_path: the kcov report dir is a throwaway outside the checkout, removed after the run (#887)" {
  local _log="${BATS_TEST_TMPDIR}/outdir.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    _out=""
    for _a in "$@"; do
      case "${_a}" in --*) continue ;; esac
      _out="${_a}"; break
    done
    printf "%s\n" "${_out}" >> "'"${_log}"'"
    mkdir -p "${_out}"
    : > "${_out}/cobertura.xml"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage_path test/bats/unit/ci_spec.bats >/dev/null
    _out="$(cat "'"${_log}"'")"
    [[ -n "${_out}" ]] || { echo "KCOV-NEVER-RAN"; exit 1; }
    [[ "${_out}" != "${REPO_ROOT}"* ]] \
      || { echo "REPORT-INSIDE-CHECKOUT: ${_out}"; exit 1; }
    [[ ! -e "${_out}" ]] || { echo "REPORT-DIR-LEFT-BEHIND: ${_out}"; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

# why: Shard independence: a planted .shard-weights pulls in nothing
@test "_run_coverage_path: kcov's exactly the named spec, never a shard slice (#887)" {
  # A weights file is planted that a greedy-LPT partition would honour, so
  # a re-implementation routed through _shard_unit_files would pull in the
  # other specs. Naming the spec must mean that spec and nothing else --
  # this is what makes the entry point behave identically on a host with no
  # restored .shard-weights and on CI where the cache restores one.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/test/bats/integration"
    for _n in a b c d; do
      printf "@test \"%s\" { :; }\n" "${_n}" > "${REPO_ROOT}/test/bats/unit/${_n}_spec.bats"
    done
    printf "%s\n" "90 a_spec.bats" "1 b_spec.bats" "80 c_spec.bats" "70 d_spec.bats" \
      > "${REPO_ROOT}/test/bats/.shard-weights"
    _die() { echo "DIE: $*"; exit 1; }
    source /source/script/test/drivers/bats.sh
    _run_coverage_path test/bats/unit/b_spec.bats >/dev/null
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "/test/bats/unit/b_spec.bats"
  refute_output --partial "a_spec.bats"
  refute_output --partial "c_spec.bats"
  refute_output --partial "d_spec.bats"
}

# why: Same instrumented tree as a shard, so the failure reproduces
@test "_run_coverage_path: instruments with the same include/exclude set a coverage shard uses (#887)" {
  # The point of the mode is to reproduce what the coverage shard does to
  # one spec. Instrument a different tree than the shard does and the
  # red-under-kcov failure it exists to reproduce may not reproduce, so
  # the two runners must hand kcov the same paths.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "bats" 'exit 0'
  # Leaves the report a real slice kcov would, so the shard's merge does
  # not refuse the slice (base#1414).
  mock_cmd "kcov" '
    [ "$1" = "--merge" ] && exit 0
    _out=""
    for _a in "$@"; do
      case "${_a}" in
        --include-path=*|--exclude-path=*) printf "%s\n" "${_a}" >> "'"${_log}"'" ;;
        -*) ;;
        *) [ -n "${_out}" ] || _out="${_a}" ;;
      esac
    done
    mkdir -p "${_out}/bats" && : > "${_out}/bats/cobertura.xml"
    exit 0'

  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/coverage" "${REPO_ROOT}/test/bats/unit" \
             "${REPO_ROOT}/test/bats/integration"
    printf "@test \"a\" { :; }\n" > "${REPO_ROOT}/test/bats/unit/a_spec.bats"
    printf "@test \"b\" { :; }\n" > "${REPO_ROOT}/test/bats/unit/b_spec.bats"
    _die() { echo "DIE: $*"; exit 1; }
    source /source/script/test/drivers/bats.sh
    _run_coverage 1/2 >/dev/null
    _run_coverage_path test/bats/unit/b_spec.bats >/dev/null
    _n="$(wc -l < "'"${_log}"'")"
    [[ "${_n}" -eq 4 ]] \
      || { echo "EXPECTED-TWO-INSTRUMENTED-RUNS-GOT-${_n}-PATH-ARGS"; exit 1; }
    _shard="$(head -2 "'"${_log}"'")"
    _single="$(tail -2 "'"${_log}"'")"
    [[ "${_shard}" == "${_single}" ]] \
      || { printf "shard:\n%s\nsingle:\n%s\n" "${_shard}" "${_single}"; exit 1; }
    printf "%s\n" "${_single}"
  '
  assert_success
  assert_output --partial "--include-path=${BATS_TEST_TMPDIR}/repo"
  assert_output --partial "--exclude-path="
}

# why: Exit-status propagation -- the loop is useless if failure is
# swallowed
@test "_run_coverage_path: propagates the spec's exit status so a red spec is a red run (#887)" {
  # The entry point exists to be a red-green loop. A runner that swallowed
  # the failure would report green on the exact run whose whole purpose is
  # to show the spec failing under instrumentation.
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" 'exit 3'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage_path test/bats/unit/ci_spec.bats >/dev/null
    echo "rc=$?"
  '
  assert_success
  assert_output "rc=3"
}

# why: Composes with --filter to instrument a single @test
@test "_run_coverage_path: BATS_FILTER appends a bats -f name filter (#887)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    BATS_FILTER="SIGTERM" _run_coverage_path test/bats/unit/ci_spec.bats >/dev/null
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "-f SIGTERM"
  assert_output --partial "test/bats/unit/ci_spec.bats"
}

# why: Dispatch: coverage service, COVERAGE_PATH plumbed, never a shard
@test "main --coverage-path: routes one spec to the coverage service with COVERAGE_PATH + BATS_ONLY=1 (#887)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  # The ambient environment this mode is actually reached from. Both other
  # selectors are set here because `_run_via_compose` forwards them FROM
  # THE ENVIRONMENT: this suite's own specs run inside a coverage shard, or
  # inside a `--coverage-local` run, and whatever that run carries is what
  # this dispatch inherits unless it says otherwise.
  run env COVERAGE_SHARD=1/4 COVERAGE_LOCAL_JOBS=32 bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/ci_spec.bats --filter shard
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
  assert_output --partial "COVERAGE_PATH=test/bats/unit/ci_spec.bats"
  assert_output --partial "BATS_FILTER=shard"
  assert_output --partial "BATS_ONLY=1"
  # Never a shard: the mode names its target, it does not partition. And
  # never a job count: this mode runs ONE spec, while a forwarded
  # COVERAGE_LOCAL_JOBS is a whole-suite parallel run's selector, ignored
  # here only because the in-container dispatch happens to read
  # COVERAGE_PATH first. An ignored value carried into the container is the
  # value a later reordering turns into a read one.
  #
  # Each refutation is paired with the positive that makes it mean
  # something, because a refutation on its own is satisfied by the
  # forwarder not carrying the selector AT ALL -- the defect base#1090 is
  # about. Measured on 1c9ccb2: with both `-e COVERAGE_SHARD=` and
  # `-e COVERAGE_LOCAL_JOBS=` deleted from `_run_via_compose`'s dispatch,
  # this case still reported `ok 1` of 1.
  #
  # The pairing is also the real contract rather than a prop for the
  # refutation. The mode CLEARS these selectors; it does not omit them. An
  # omitted `-e` leaves the container to take the name from the service
  # definition instead of from the dispatch, so the one place that decides
  # what this mode runs would no longer be the dispatch -- which is why
  # `_run_via_compose` forwards each as `-e NAME="${NAME:-}"` and why
  # coverage_local_spec's roster guard reads that shape off this very
  # dispatch.
  assert_output --partial "COVERAGE_SHARD="
  refute_output --regexp 'COVERAGE_SHARD=[0-9]'
  assert_output --partial "COVERAGE_LOCAL_JOBS="
  refute_output --regexp 'COVERAGE_LOCAL_JOBS=[0-9]'
}

# why: In-container branch sits ahead of _run_coverage; no report line
@test "main --ci: COVERAGE=1 with COVERAGE_PATH runs the one spec and reports no coverage figure (#887)" {
  # The in-container dispatch must branch BEFORE _run_coverage, which
  # kcov's the whole suite and writes coverage/timings.tsv + the report
  # line into the mounted checkout.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  _kcov_slice_mock "${_log}"
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    # A marker on the runner this branch must NOT reach. Refuting it is a
    # stronger reading than refuting the report line, and it also keeps
    # the day the branch regresses from writing coverage/timings.tsv into
    # the mounted checkout while the assertion is still red.
    _run_coverage() { printf "REACHED-FULL-RUNNER\n"; }
    # Every other selector the dispatch forwards is pinned for the same
    # reason the marker exists: COVERAGE_PATH is asserted to out-rank
    # them, and a block that inherited one from the run it is inside
    # would be asserting that only for whichever run happened to be in
    # flight. LINT_ONLY earns its place too -- set, it returns from this
    # dispatch before the coverage branch is read.
    COVERAGE=1 COVERAGE_PATH=test/bats/unit/ci_spec.bats COVERAGE_SHARD= \
      COVERAGE_LOCAL_JOBS= BATS_ONLY=0 BATS_UNIT_SHARD= BATS_FRAGILE=0 \
      BATS_INTEGRATION=0 BATS_FILE= BATS_FILTER= LINT_ONLY=0 LINT_TOOL= LINT_GROUP= PER_TEST_TIMEOUT= \
      COVERAGE_JOBS= SHARD_WEIGHTS_BLOB= \
      main --ci
  '
  assert_success
  refute_output --partial "REACHED-FULL-RUNNER"
  refute_output --partial "Coverage report:"
  refute_output --partial "full suite"

  run cat "${_log}"
  assert_success
  assert_output --partial "test/bats/unit/ci_spec.bats"
  refute_output --partial "/test/bats/integration/ "
}

# why: Host-side missing-path guard
@test "main --coverage-path: non-existent path dies before docker is called (#887)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/does_not_exist_spec.bats
  '
  assert_failure
  assert_output --partial "No such spec file or directory"
  refute_output --partial "docker should not be called"
}

# why: Host-side system-spec guard (needs the ci-system service)
@test "main --coverage-path: test/bats/system/ dies with the ci-system hint (#887)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/system/runtime_test_smoke_spec.bats
  '
  assert_failure
  assert_output --partial "ci-system"
  refute_output --partial "docker should not be called"
}

# why: A figure over a partition and one instrumented spec are different
# asks
@test "main --coverage-path + --coverage-shard is rejected (#887)" {
  # One asks for a figure over a partition, the other for instrumentation
  # over one named spec. Silently letting one win would be how a one-spec
  # run ends up uploaded as a shard.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/ci_spec.bats --coverage-shard 1/4
  '
  assert_failure
  assert_output --partial "--coverage-path"
  assert_output --partial "cannot combine"
  refute_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

# why: Two runners, two services -- refused by name
@test "main --coverage-path + --bats-path is rejected (#887)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/ci_spec.bats --bats-path test/bats/unit/lib_spec.bats
  '
  assert_failure
  assert_output --partial "--coverage-path"
  assert_output --partial "cannot combine"
  refute_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

# why: #523's refusal is intact; the combination is --coverage-path
@test "main --bats-path + --coverage stays rejected: the fast loop is still kcov-free (#887)" {
  # --coverage-path did NOT lift the original refusal. --bats-path is the
  # no-kcov loop by definition; combining it with --coverage would have
  # meant one flag pair with two runners behind it.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/ci_spec.bats --coverage
  '
  assert_failure
  assert_output --partial "cannot combine with --coverage"
  assert_output --partial "--coverage-path"
  refute_output --partial "docker should not be called"
}

# why: #692 unknown-flag guard
@test "main: unknown option dies with ci_unknown_option (#692)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bogus
  '
  assert_failure
  assert_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

# why: #692 narrowing-flag typo guard
@test "main: --hadolint without --lint dies (narrowing flag, not standalone) (#692)" {
  # `--hadolint` narrows --lint; standalone is the easy-to-make typo for
  # --hadolint-only. It must fail loudly, not silently no-op.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --hadolint
  '
  assert_failure
  assert_output --partial "narrows --lint"
  refute_output --partial "docker should not be called"
}

# why: base#1412. `--group` narrows `--lint` the way `--hadolint` does;
# standalone it is a typo, and with a tool it asks for two narrowings of
# one run. Both refuse before compose, so neither costs an image or runs
# a lint the caller did not ask for.
@test "main: --group without --lint, or beside a tool, dies before compose (base#1412)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --group 1/4
  '
  assert_failure
  assert_output --partial "narrows --lint"
  refute_output --partial "docker should not be called"

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --lint --group 1/4 --shellcheck
  '
  assert_failure
  assert_output --partial "two narrowings of --lint"
  refute_output --partial "docker should not be called"
}

# why: base#1412. A malformed group spec is refused on the host, before
# compose: it is a typo, and a typo should cost no image build.
@test "main: --lint --group refuses a malformed spec before compose (base#1412)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --lint --group 9/4
  '
  assert_failure
  assert_output --partial "lint group '9/4' is outside its own total"
  refute_output --partial "docker should not be called"
}

# why: base#1412. LINT_GROUP is how the in-image lint-static job selects
# its group; it has to reach `_run_lint_group`, whose refusal of an
# out-of-range spec is the observable proof that the group branch, not the
# whole-phase or single-tool branch, took the run.
@test "main --ci: LINT_GROUP routes the lint-only run to one group (base#1412)" {
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL= LINT_GROUP=9/4 main --ci
  '
  assert_failure
  assert_output --partial "lint group '9/4' is outside its own total"
}

# why: base#1412 review round 7. CI lints inside the test-tools image, as
# the local gate does. A reading of the workflow cannot see every way a
# step reaches a host arm (a value an earlier step put in $GITHUB_ENV, a
# step that runs only on some runs), so the one lint dispatch refuses a CI
# runner's host itself. Every host entry point goes through it: the
# --<tool>-only family, --hadolint-only, --lint-group and `--ci` run on
# the host. None of them may reach a driver.
@test "_run_lint_tool: every host lint entry point is refused on a CI runner (base#1412)" {
  local _entry
  local -a _entries=(
    'main --doc-counts-only'
    'main --hadolint-only'
    'main --lint-group 1/4'
    'LINT_ONLY=1 LINT_TOOL=doc-counts main --ci'
    'LINT_ONLY=1 LINT_TOOL= LINT_GROUP= main --ci'
  )
  for _entry in "${_entries[@]}"; do
    run env LOG_FORMAT=json bash -c '
      source /source/script/test/test.sh
      # Every driver the one dispatch names, read from its own body.
      for _f in $(declare -f _run_lint_tool | grep -oE "\b_run_[a-z_]+" | sort -u | grep -vx _run_lint_tool); do
        eval "${_f}() { echo REACHED-DRIVER; }"
      done
      [ "$(_run_doc_counts)" = REACHED-DRIVER ] && [ "$(_run_hadolint)" = REACHED-DRIVER ] \
        || { echo "BUG: the drivers were not stubbed"; exit 0; }
      export GITHUB_ACTIONS=true
      '"${_entry}"'
    '
    assert_failure
    assert_output --partial '"body":"ci_host_lint_on_runner"'
    refute_output --partial "REACHED-DRIVER"
  done
}

# why: base#1412 review round 7. The refusal is the runner's mark, not a
# refusal of host arms: off a runner an operator still times one driver
# with them.
@test "_run_lint_tool: off a CI runner a host arm still reaches its driver (base#1412)" {
  run bash -c '
    source /source/script/test/test.sh
    _run_doc_counts() { echo REACHED-DRIVER; }
    unset GITHUB_ACTIONS
    main --doc-counts-only
  '
  assert_success
  assert_output --partial "REACHED-DRIVER"
  refute_output --partial "ci_host_lint_on_runner"
}

# why: #692 LINT_TOOL validation
@test "main --ci: unknown LINT_TOOL dies with ci_unknown_lint_tool (#692)" {
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=bogus main --ci
  '
  assert_failure
  assert_output --partial "Unknown LINT_TOOL"
}

# why: #845 stale setup.conf lint reaches the CI gate
@test "main --ci: LINT_TOOL=stale-setup-conf runs the stale setup.conf lint (#845)" {
  # Wiring guard: the lint must reach the CI gate, not only an Edit-time
  # hook. An unwired tool falls through to the ci_unknown_lint_tool branch
  # (the test above), so a passing run here proves the dispatch case exists.
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=stale-setup-conf main --ci
  '
  assert_success
  assert_output --partial "stale setup.conf path lint: clean"
}

# why: #846 localized README sync lint reaches the CI gate
@test "main --ci: LINT_TOOL=readme-sync runs the localized README sync lint (#846)" {
  # Wiring guard: the translation drift guard must reach the CI gate, not
  # only the on-demand generator. An unwired tool falls through to the
  # ci_unknown_lint_tool branch, so a passing run here proves the dispatch
  # case exists.
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=readme-sync main --ci
  '
  assert_success
  assert_output --partial "localized README sync lint: clean"
}

# why: #864 doc/test count drift gate reaches the CI gate
@test "main --ci: LINT_TOOL=doc-counts runs the doc/test count drift gate (#864)" {
  # Wiring guard: the doc-count drift gate must reach the CI gate, not only
  # `just test sync-docs-check` and the advisory harness hook. An unwired
  # tool falls through to the ci_unknown_lint_tool branch, so a passing run
  # here proves the dispatch case exists.
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=doc-counts main --ci
  '
  assert_success
  assert_output --partial "doc/test count drift gate: clean"
}

# why: #864 host-direct primitive so a CI job can run the gate without
# compose
@test "main --doc-counts-only: runs the drift gate on the host, no compose (#864)" {
  # The host-direct arm is kept to time one driver; CI runs the gate with
  # --lint --doc-counts inside the test-tools image instead (base#1412).
  # Docker must not be touched on this path.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --doc-counts-only
  '
  assert_success
  assert_output --partial "doc/test count drift gate: clean"
  refute_output --partial "docker should not be called"
}

@test "main --issueref-only: runs the issue-ref comment lint on the host, no compose (#866)" {
  # CI-reachability guard, same shape as --doc-counts-only / --shellcheck-only.
  # The lint phase is what enforces ADR-00000013, and no CI job ran that
  # phase, so the rule gated nothing on a PR. A lint-static group runs this
  # driver on a plain ubuntu-latest runner; docker must not be touched on
  # the path.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --issueref-only
  '
  assert_success
  assert_output --partial "issue-ref comment lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --adr-structure-only: runs the ADR-structure lint on the host, no compose (#994)" {
  # Ungated in CI for the same reason its sibling is: an ADR body is a
  # doc-only change, so a code_changed gate would skip the lint on exactly
  # the PR that lands a malformed ADR. That only works host-direct.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --adr-structure-only
  '
  assert_success
  assert_output --partial "ADR-structure lint:"
  assert_output --partial "clean"
  refute_output --partial "docker should not be called"
}

@test "main --adr-numbering-only: runs the ADR-numbering lint on the host, no compose (#866)" {
  # Ungated in CI on purpose: doc/adr/ filenames are a doc-only change, so a
  # code_changed gate would skip the lint on exactly the PR that duplicates
  # an ADR number. That only works if the lint is host-direct.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --adr-numbering-only
  '
  assert_success
  assert_output --partial "ADR-numbering lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --stale-setup-conf-only: runs the stale setup.conf path lint on the host, no compose (#866)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --stale-setup-conf-only
  '
  assert_success
  assert_output --partial "stale setup.conf path lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --home-literal-only: runs the hardcoded home path lint on the host, no compose (#799)" {
  # Same CI-reachability shape as the sibling primitives: a lint-static
  # group runs this driver on a plain ubuntu-latest runner, so it must be
  # pure bash over the checkout and never touch docker.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --home-literal-only
  '
  assert_success
  assert_output --partial "hardcoded home path lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --changelog-entry-only: runs the changelog entry-length lint on the host, no compose (#917)" {
  # Same CI-reachability shape as the sibling primitives: a lint-static
  # group runs this driver on a plain ubuntu-latest runner, so it must be
  # pure bash over the checkout and never touch docker.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --changelog-entry-only
  '
  assert_success
  assert_output --partial "changelog entry lint:"
  refute_output --partial "docker should not be called"
}

# why: The CI join is host-direct, like its siblings
@test "main --action-ref-agreement-only: runs the action ref agreement lint on the host, no compose (#949)" {
  # Same CI-reachability shape as the sibling primitives: a lint-static
  # group runs this driver on a plain ubuntu-latest runner, so it must be
  # pure bash over the checkout and never touch docker.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --action-ref-agreement-only
  '
  assert_success
  assert_output --partial "action ref agreement lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --readme-sync-only: runs the localized README sync lint on the host, no compose (#866)" {
  # The clearest case for an ungated CI job: a README.md edit that leaves a
  # translation behind is a doc-only change end to end.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --readme-sync-only
  '
  assert_success
  assert_output --partial "localized README sync lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main: _LINT_TOOLS is the one table every lint-phase caller dispatches through (#866)" {
  # Three callers used to repeat the tool list (the full phase, the
  # in-container LINT_TOOL narrowing, the host-direct --<tool>-only
  # primitives), so a new lint could be wired into one and missed by the
  # others. They now share this table, which is also what the
  # self-test.yaml completeness guard reads to prove every lint has a CI
  # job.
  run bash -c '
    source /source/script/test/test.sh
    printf "%s\n" "${_LINT_TOOLS[@]}"
  '
  assert_success
  assert_line "shellcheck"
  assert_line "hadolint"
  assert_line "issueref"
  assert_line "adr-numbering"
  assert_line "adr-structure"
  assert_line "stale-setup-conf"
  assert_line "readme-sync"
  assert_line "doc-counts"
  assert_line "home-literal"
  assert_line "changelog-entry"
  assert_line "action-ref-agreement"
}

# why: #523 filter-only dispatch
@test "main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --filter cap_add
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "BATS_FILTER=cap_add"
  assert_output --partial "BATS_ONLY=1"
  assert_output --partial "BATS_FILE= "
}

# why: #523 single-path runner
@test "_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    BATS_FILE="test/bats/unit/ci_spec.bats" BATS_FILTER="shard" _run_bats_path
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "test/bats/unit/ci_spec.bats"
  assert_output --partial "-f shard"
}

# why: #523 filter-only runner
@test "_run_bats_path: filter-only runs bats across unit + integration" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    BATS_FILE="" BATS_FILTER="cap_add" _run_bats_path
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "test/bats/unit/"
  assert_output --partial "test/bats/integration/"
  assert_output --partial "-f cap_add"
}
