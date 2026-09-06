#!/usr/bin/env bats
#
# The operator-facing claims that MISCONFIGURE THE PRODUCT when they are wrong.
#
# Not a doc-sync tool and not a spell check. The four READMEs each carried one
# instruction -- the primary override in Quick Start -- written in a grammar
# `setup.sh` does not accept:
#
#     [environment]
#     SIGNALING_SERVER = <host-ip>          <- dropped, no warning, exit 0
#     env_1 = SIGNALING_SERVER=<host-ip>    <- what setup.sh collects
#
# Reproduced on a scratch copy of this repo before this spec was written:
# with the README's form, `./script/setup.sh apply` exits 0 with zero warnings
# and the generated compose.yaml contains no SIGNALING_SERVER at all; with the
# env_N form, compose.yaml carries it. An operator who followed the primary
# instruction got a viewer dialling 127.0.0.1, HTTP 200, and no picture --
# indistinguishable from a broken producer. It shipped for four versions
# because nothing in this repo reads a README.
#
# So the assertion is narrow on purpose: every KEY in the READMEs'
# `[environment]` example must be one setup.sh actually collects, and the keys
# the example names must exist in the shipped setup.conf. A README that drifts
# from the file it tells you to edit is a red test.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  DOC_DIR="/doc"
  READMES=(
    "${DOC_DIR}/README.md"
    "${DOC_DIR}/README.zh-TW.md"
    "${DOC_DIR}/README.zh-CN.md"
    "${DOC_DIR}/README.ja.md"
  )
  SETUP_CONF="${DOC_DIR}/setup.conf"
}

# _environment_block <file>: the lines between `[environment]` and the end of
# that fenced block, assignments only.
_environment_block() {
  awk '
    /^\[environment\]$/ { inblock = 1; next }
    inblock && /^```/   { exit }
    inblock && /=/      { print }
  ' "$1"
}

# why: The operator-facing claims that MISCONFIGURE THE PRODUCT when they
# are wrong. Not a doc-sync tool and not a spell check: the four READMEs
# each told the user to write `SIGNALING_SERVER = <host-ip>` under
# `[environment]` in `config/docker/setup.conf`, and the grammar is `env_N =
# KEY=VALUE` -- base's `setup.sh` collects only keys beginning `env_`, and
# one that does not is dropped with no warning and exit 0. Reproduced on a
# scratch copy before this spec was written: with the README's form
# `./script/setup.sh apply` exits 0 with zero warnings and the generated
# `compose.yaml` contains no `SIGNALING_SERVER` at all; with the `env_N`
# form it carries it. An operator following the primary override instruction
# got a viewer dialling `127.0.0.1`, HTTP 200, and no picture --
# indistinguishable from a broken producer. It shipped for four versions
# because nothing in this repo reads a README. The `devel-test` stage
# `COPY`s the four READMEs and `setup.conf` to `/doc/`, below the lint RUNs
# for the same layer-invalidation reason the workflow COPY gives.


# why: The spec is worthless if its inputs are missing
@test "readme: the docs and setup.conf are both in the image" {
  for f in "${READMES[@]}"; do
    [ -f "${f}" ] || { echo "missing: ${f}" >&2; return 1; }
  done
  [ -f "${SETUP_CONF}" ]
}

# why: Every key in the fenced `[environment]` example must be `env_N`;
# asserts the block was non-empty, so an example that disappears is not a
# silent pass
@test "readme: the [environment] example uses the grammar setup.sh collects" {
  local f line key found=0
  for f in "${READMES[@]}"; do
    while IFS= read -r line; do
      found=1
      key="${line%%=*}"
      key="${key// /}"
      case "${key}" in
        env_[0-9]*) ;;
        *)
          echo "${f}: '${line}' -- setup.sh collects only env_N keys, so this" >&2
          echo "  is dropped with no warning and the operator gets 127.0.0.1" >&2
          return 1
          ;;
      esac
    done < <(_environment_block "${f}")
  done
  # The block must not be empty, or this case proves nothing.
  [ "${found}" -eq 1 ]
}

# why: The README cannot name a variable the shipped `setup.conf` does not
# set
@test "readme: every variable the example names exists in setup.conf" {
  local line var
  while IFS= read -r line; do
    var="${line#*=}"          # env_1 = SIGNALING_SERVER=<host-ip>
    var="${var%%=*}"          # SIGNALING_SERVER
    var="${var// /}"
    grep -qE "^env_[0-9]+ *= *${var}=" "${SETUP_CONF}" || {
      echo "README names ${var} but setup.conf has no env_N for it" >&2
      return 1
    }
  done < <(_environment_block "${READMES[0]}")
}

# why: The other direction: the file the README points at must itself hold
# the grammar
@test "readme: setup.conf's own [environment] keys are all env_N" {
  run bash -c "sed -n '/^\[environment\]/,/^\[/p' '${SETUP_CONF}' \
                 | grep -E '^[A-Za-z][A-Za-z0-9_]* *=' \
                 | grep -vE '^env_[0-9]+ *='"
  assert_failure
}
