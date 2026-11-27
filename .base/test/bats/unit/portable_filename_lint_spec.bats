#!/usr/bin/env bats
#
# why: The guard that keeps every path in this tree creatable on Windows.
# The whole repository is carried into downstream repos as their `.base/`
# subtree, so one name Windows refuses makes each of those repos
# impossible to check out there. A golden named after its INI section,
# `stage:dev`, did exactly that: Linux and CI saw nothing, and a Windows
# checkout stopped at `error: invalid path`.
#
# A path is refused when any component holds one of the characters
# Windows reserves in a file name -- `<` `>` `:` `"` `|` `?` `*` and the
# backslash -- or a control character, or ends in a dot or a space.
#
# The scan walks the mounted tree with `find` rather than asking git:
# the suite runs in a container that cannot always resolve the checkout's
# `.git`, and a check that passed wherever git was unreadable would pass
# in the place it runs most. The directories pruned from the walk are the
# derived ones `.gitignore` names that hold other trees or timestamped
# names; nothing tracked lives under them.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  assert_spec_subject_dir "/source/dockerfile/config-gen/testdata"
}

# _nonportable_names -- stdin: NUL-separated repo-relative paths; stdout:
# one line per path Windows cannot create. Prints nothing for a clean set.
_nonportable_names() {
  LC_ALL=C grep -z -E '[<>:"|?*\\[:cntrl:]]|[. ](/|$)' | tr '\0' '\n' || true
}

# _tree_names <root> -- the NUL-separated paths under <root>, files and
# directories both, minus the derived directories. Each path keeps its
# <root> prefix: the suite image carries the busybox find, which has no
# `-printf` to cut it off.
_tree_names() {
  local _root="${1}"
  find "${_root}" -mindepth 1 \
    \( -path "${_root}/.git" -o -path "${_root}/.prev-release" \
    -o -path "${_root}/.claude" -o -path "${_root}/coverage" \
    -o -path "${_root}/coverage-shards" -o -type d -name log \) -prune \
    -o -print0
}

# why: each reserved character is its own way to break a checkout, and a
# rule that lost one of them would still pass on the other seven.
@test "a name holding any one character Windows reserves is reported" {
  local _c _missed=""
  for _c in '<' '>' ':' '"' '|' '?' '*' '\'; do
    run _nonportable_names < <(printf '%s\0' "dir/a${_c}b.golden" "dir/plain.golden")
    [[ "${output}" == "dir/a${_c}b.golden" ]] || _missed+=" ${_c}"
  done
  [[ -z "${_missed}" ]] || fail "not reported alone:${_missed}"
}

# why: Windows drops a trailing dot or space when it creates a name, so
# the file git wrote is not the file git then looks for.
@test "a file or directory name ending in a dot or a space is reported" {
  run _nonportable_names < <(printf '%s\0' \
    "dir/ends." "dir/ends " "ends./file" "ends /file" "dir/fine")
  assert_equal "${output}" $'dir/ends.\ndir/ends \nends./file\nends /file'
}

# why: a control character in a name is refused by Windows as well, and
# a newline in one would otherwise split into two innocent-looking names.
@test "a name holding a control character is reported" {
  run _nonportable_names < <(printf '%s\0' $'dir/tab\there' "dir/fine")
  assert_equal "${output}" $'dir/tab\there'
}

# why: the control group -- dots and spaces inside a name, a leading dot
# and the percent-encoding that replaces a colon are all legal, and a rule
# that refused them would send people to rename files that work.
@test "names Windows accepts are not reported" {
  run _nonportable_names < <(printf '%s\0' \
    ".hidden" "a.b.c" "with space.txt" "dir.d/file" \
    "s25_dotted_keys.dump.stage%3Adev.golden" "a-b_c+d@e,f=g" "README.zh-TW.md")
  assert_equal "${output}" ""
}

# why: the walk is the half the pure rule cannot vouch for -- a planted
# name has to reach the rule, and the derived directories must not.
@test "the tree walk reaches a planted name and skips the derived directories" {
  local _root="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${_root}/sub/deep" "${_root}/.git" "${_root}/.prev-release/v1" \
    "${_root}/sub/log"
  : > "${_root}/sub/deep/a:b"
  : > "${_root}/sub/ok"
  : > "${_root}/.git/x:y"
  : > "${_root}/.prev-release/v1/x:y"
  : > "${_root}/sub/log/12:00:00.log"
  run _nonportable_names < <(_tree_names "${_root}")
  assert_equal "${output}" "${_root}/sub/deep/a:b"
}

# why: this is the gate itself. The walk must have seen the tree -- this
# file among it -- or an empty answer would mean nothing was asked.
@test "no path in this tree is one Windows cannot create (base#2226)" {
  local _n
  _n="$(_tree_names /source | tr '\0' '\n' \
    | grep -c -x '/source/test/bats/unit/portable_filename_lint_spec.bats' || true)"
  assert_equal "${_n}" "1"
  run _nonportable_names < <(_tree_names /source)
  [[ -z "${output}" ]] || fail "paths Windows cannot create (rename them; a reserved character can be percent-encoded, as golden/s25 does for ':'):
${output}"
}
