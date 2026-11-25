#!/usr/bin/env bash
#
# upstream.sh - where `base` itself comes from.
#
# One definition, three consumers: upgrade.sh (the `git subtree pull` that
# rewrites .base/ AND the "is there a newer tag" query), init.sh (the same
# query on a subtree that has no .version yet) and check-base-version.sh
# (the release poll, plus the release link it writes into a real GitHub
# issue). Each used to carry its own copy of the literal, so pointing a
# repo at a different supply meant finding all of them -- and a stale one
# kept asking the old upstream.
#
# Everything fetched from here is then EXECUTED in the consumer's tree
# (wrappers, libs, the Dockerfile, the entrypoint), which is why the value
# gets one auditable definition rather than three.
#
# These are constants, not knobs: nothing here reads the environment. The
# per-run overrides are TEMPLATE_REMOTE (upgrade.sh / init.sh) and
# BASE_REPO (check-base-version.sh), applied by those scripts and
# documented in README "Pointing .base at a different upstream".
#
# Sourced, never executed. No side effects beyond the two assignments.

if [[ -n "${_BASE_UPSTREAM_SOURCED:-}" ]]; then
  return 0
fi
_BASE_UPSTREAM_SOURCED=1

# GitHub <owner>/<repo> of upstream base. check-base-version.sh queries
# `repos/<slug>/releases/latest` through it and puts it in the release
# link of the reminder issue it files.
BASE_UPSTREAM_SLUG='ycpss91255-lab/base'

# The slug base was published under before the org was renamed. Nothing
# resolves it any more, but a downstream main.yaml written by an older
# init.sh still names it, so upgrade.sh moves those `uses:` refs to the
# slug above. An extended regex with no capture group, so a caller can
# splice it into its own sed pattern without renumbering that pattern's
# groups; the bracket also keeps this line from spelling the retired name
# in one piece, which the org-name spec refuses everywhere else.
# shellcheck disable=SC2034 # read by the scripts that source this file.
BASE_UPSTREAM_RETIRED_RE='ycpss91255-[d]ocker/base'

# The clone URL upgrade.sh / init.sh default to. HTTPS so a fresh clone, a
# CI runner or a first-time contributor with no SSH key works out of the
# box; TEMPLATE_REMOTE is how a caller opts into SSH or a private fork.
# shellcheck disable=SC2034 # read by the scripts that source this file.
BASE_UPSTREAM_REMOTE="https://github.com/${BASE_UPSTREAM_SLUG}.git"
