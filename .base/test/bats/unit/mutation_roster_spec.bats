#!/usr/bin/env bats
#
# mutation_roster_spec.bats -- the committed required-kill roster,
# script/test/mutation_required/ (base#1461), read as data: how its rows
# are dealt and weighed for the mutation-roster matrix (base#1571). The
# per-row contract cases are in mutation_roster_rows_spec.bats.
#
# why a spec of its own: every case here reads a committed row against its
# subject's bytes in /source. A probe of a row mutates that subject in its
# sandbox's /source, so under the row's mutant <old> is no longer in the
# subject and these cases go red whatever the row's own test does. Measured
# at 8c81f155, when they were cases of mutation_required_spec.bats: probing
# s1571.tsv's deal-by-index and slot-reset-hard rows there turned these
# four cases red beside the one behaviour test each row names, so either
# row read PINNED with that test gone (base#1571). Here no row can name
# them: the last case refuses a committed row whose spec is this file or
# mutation_roster_rows_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  MR="/source/script/test/drivers/mutation_required.sh"
  S="${BATS_TEST_TMPDIR}"
  # Out of /source: a worktree checkout's .git there names a host path the
  # container does not mount.
  cd "${S}"
  unset COMPOSE_PROJECT_NAME MUTATION_REQUIRED_JOBS MUTATION_REQUIRED_PROBE \
    GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE PER_TEST_TIMEOUT
}

# ── the committed roster's shards ───────────────────────────────────────────

# why: The roster leaves lint-static for the mutation-roster matrix, and
# its rows are dealt by recorded seconds, not by index (base#1571). The set
# of rows a PR run probes must still be the whole roster, each row once,
# and a spec has to compare the union of the shard row lists with the full
# roster to show it. `--check --shard <n>/<total>` validates every row,
# probes nothing, and logs one mutation_required_row_dealt line per row of
# shard <n> (row=<file>:<line>). Over the committed roster, with the shard
# count of self-test.yaml's mutation-roster matrix, the union of those
# lists is every non-blank, non-`#` line of every roster file, read here
# straight from the TSVs, and no row is in two shards.
@test "shards: over the committed roster the mutation-roster shards' row lists are every row, each once (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _wf=/source/.github/workflows/self-test.yaml _t _k _want _got
  _t="$(yq '.jobs.mutation-roster.strategy.matrix.shard | length' "${_wf}")"
  [[ "${_t}" =~ ^[1-9][0-9]*$ ]] && (( _t >= 2 )) \
    || fail "self-test.yaml's mutation-roster matrix has '${_t}' shards"
  _want="$(cd /source && LC_ALL=C awk '
    FNR == 1 { f = FILENAME }
    $0 != "" && substr($0, 1, 1) != "#" { print f ":" FNR }
  ' script/test/mutation_required/*.tsv | LC_ALL=C sort)"
  [[ -n "${_want}" ]] || fail "the committed roster holds no row"
  _got=""
  for (( _k = 1; _k <= _t; _k++ )); do
    run --separate-stderr env LOG_FORMAT=json bash "${MR}" --check --root /source --shard "${_k}/${_t}"
    assert_success
    _got+="$(grep -F '"body":"mutation_required_row_dealt"' <<< "${stderr}" \
      | sed -n 's/.*"row":"\([^"]*\)".*/\1/p')"$'\n'
  done
  _got="$(grep -v '^$' <<< "${_got}" | LC_ALL=C sort || true)"
  [[ -n "${_got}" ]] || fail "--check --shard logged no mutation_required_row_dealt line for any of the ${_t} shards"
  local _dups
  _dups="$(uniq -d <<< "${_got}")"
  [[ -z "${_dups}" ]] || fail "rows dealt to more than one shard:"$'\n'"${_dups}"
  assert_equal "${_got}" "${_want}"
}

# why: --shard deals by script/test/mutation_required/seconds.txt, and a
# row the file does not name weighs 0 (base#1571), so a shard balanced on
# a file that misses rows is balanced on a guess, not on a measurement.
# The committed file must name every committed roster row -- the pair
# <roster file basename> TAB <id>, read here straight from the TSVs --
# exactly once, each with a positive number of seconds, and no row that
# the roster does not hold.
@test "shards: the committed seconds.txt weighs every committed roster row once, each with positive seconds (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _sec=/source/script/test/mutation_required/seconds.txt _want _got _bad _dups
  [[ -f "${_sec}" ]] \
    || fail "the committed roster has no seconds.txt, so --shard deals every row at weight 0"
  _want="$(cd /source/script/test/mutation_required && LC_ALL=C awk -F '\t' '
    $0 != "" && substr($0, 1, 1) != "#" { print FILENAME "\t" $1 }
  ' ./*.tsv | sed 's|^\./||' | LC_ALL=C sort)"
  [[ -n "${_want}" ]] || fail "the committed roster holds no row"
  _bad="$(LC_ALL=C awk -F '\t' 'NF != 3 || $3 !~ /^[0-9]+(\.[0-9]+)?$/ || $3 + 0 <= 0' "${_sec}")"
  [[ -z "${_bad}" ]] || fail "seconds.txt lines that are not <file> TAB <id> TAB <positive seconds>:"$'\n'"${_bad}"
  _got="$(cut -f1,2 "${_sec}" | LC_ALL=C sort)"
  _dups="$(uniq -d <<< "${_got}")"
  [[ -z "${_dups}" ]] || fail "seconds.txt weighs these rows more than once:"$'\n'"${_dups}"
  assert_equal "${_got}" "${_want}"
}

# _leg_bound <jobs> -- the list-scheduling (Graham) bound on the wall time
# of <jobs> worker slots running the rows whose seconds are on stdin, one
# per line, in any dispatch order: sum/jobs + max * (1 - 1/jobs).
_leg_bound() {
  LC_ALL=C awk -v jobs="${1}" '
    { s += $1; if ($1 + 0 > m) m = $1 + 0 }
    END { printf "%.1f\n", s / jobs + m * (1 - 1 / jobs) }
  '
}

# why: The owner's target is at most 5 minutes per CI job (base#1582).
# With a witness on every row (base#1582) a row waits on no other row's
# baseline, so its measured seconds are its own work: two filtered runs,
# or those plus the whole spec mutated and unmutated when the filtered
# pass stays green. Row seconds therefore add up, and the
# list-scheduling bound sum/J + max*(1-1/J) turns them into a wall-time
# bound for J worker slots whatever order the rows are dispatched in;
# sum/J alone is not one (worked literal: J=4, rows 100,10,10,10 ->
# sum/J = 32.5, but the 4-slot wall is 100; the bound is 32.5 + 75 =
# 107.5). For every leg k/N of self-test.yaml's mutation-roster matrix,
# the rows `--check --shard k/N` deals are looked up in the committed
# seconds.txt (each row=<file>:<line> read back from its TSV line to its
# <file> TAB <id>) and bounded over the leg's worker slots
# (MUTATION_REQUIRED_JOBS on the job, else the driver's default of 4).
# That bound must be at most 240 s: 300 s less the measured 25 s fixed
# cost per job (before the first row, after the last) and a 35 s margin.
@test "shards: every mutation-roster leg's list-scheduling bound over its worker slots fits 240 s (base#1582)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  run _leg_bound 4 <<< $'100\n10\n10\n10'
  assert_success
  assert_output "107.5"
  local _wf=/source/.github/workflows/self-test.yaml
  local _sec=/source/script/test/mutation_required/seconds.txt _t _k _jobs _rows _bound _over=""
  [[ -f "${_sec}" ]] || fail "the committed roster has no seconds.txt"
  _t="$(yq '.jobs.mutation-roster.strategy.matrix.shard | length' "${_wf}")"
  [[ "${_t}" =~ ^[1-9][0-9]*$ ]] && (( _t >= 2 )) \
    || fail "self-test.yaml's mutation-roster matrix has '${_t}' shards"
  _jobs="$(yq '.jobs.mutation-roster.env.MUTATION_REQUIRED_JOBS // 4' "${_wf}")"
  [[ "${_jobs}" =~ ^[1-9][0-9]*$ ]] || fail "mutation-roster sets MUTATION_REQUIRED_JOBS to '${_jobs}'"
  for (( _k = 1; _k <= _t; _k++ )); do
    run --separate-stderr env LOG_FORMAT=json bash "${MR}" --check --root /source --shard "${_k}/${_t}"
    assert_success
    _rows="$(grep -F '"body":"mutation_required_row_dealt"' <<< "${stderr}" \
      | sed -n 's/.*"row":"\([^"]*\)".*/\1/p')"
    [[ -n "${_rows}" ]] || fail "--check --shard ${_k}/${_t} dealt no row"
    printf '%s\n' "${_rows}" > "${BATS_TEST_TMPDIR}/dealt"
    _bound="$(cd /source && LC_ALL=C awk -F '\t' '
      FILENAME ~ /dealt$/ { split($0, r, ":"); want[r[1] FS r[2]] = 1; next }
      FILENAME ~ /seconds\.txt$/ { sec[$1 FS $2] = $3 + 0; next }
      (FILENAME FS FNR) in want { n = FILENAME; sub(/.*\//, "", n); print sec[n FS $1] }
    ' "${BATS_TEST_TMPDIR}/dealt" "${_sec}" script/test/mutation_required/*.tsv | _leg_bound "${_jobs}")"
    awk -v b="${_bound}" 'BEGIN { exit !(b + 0 <= 240) }' \
      || _over+="leg ${_k}/${_t}: ${_bound} s over ${_jobs} worker slots"$'\n'
  done
  [[ -z "${_over}" ]] \
    || fail "mutation-roster legs whose list-scheduling bound exceeds 240 s:"$'\n'"${_over}"
}

# why: A row's spec is what the probe runs against that row's mutant, and
# the other cases in this file and in mutation_roster_rows_spec.bats read
# the committed roster against its subject's bytes, so a row naming either
# file would read PINNED from those cases whatever its own test does. Read
# straight from the TSVs.
@test "roster: no committed row names this spec, which reads every row against its subject (base#1571)" {
  assert_spec_subject_dir /source/script/test/mutation_required "the committed roster"
  local _self _rows _bad
  _self="test/bats/unit/$(basename "${BATS_TEST_FILENAME}")"
  _rows="test/bats/unit/mutation_roster_rows_spec.bats"
  [[ -f "/source/${_rows}" ]] || fail "no ${_rows}: the guard would cover a file that does not exist"
  _bad="$(cd /source/script/test/mutation_required && LC_ALL=C awk -F '\t' -v self="${_self}" -v rows="${_rows}" '
    $0 != "" && substr($0, 1, 1) != "#" && ($3 == self || $3 == rows) { print FILENAME ": " $1 " (" $3 ")" }
  ' ./*.tsv)"
  [[ -z "${_bad}" ]] || fail "rows probed under ${_self} or ${_rows}:"$'\n'"${_bad}"
}
