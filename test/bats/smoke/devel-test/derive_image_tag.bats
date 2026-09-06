#!/usr/bin/env bats
#
# Contract smoke for script/ci/derive_image_tag.sh (#66).
#
# The image tag published to GHCR must be DERIVED from the git ref, never typed
# in, so a release and its image cannot drift apart. That derivation is the one
# piece of the tag-triggered publish path that CAN be proven without pushing a
# tag -- the workflow wiring around it cannot -- so it is exercised here over
# the full table of refs a real push would produce.
#
# The script is copied into the image at /ci/ by the `devel-test` stage.

DERIVE="/ci/derive_image_tag.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# Resolved tag on stdout, provenance chatter dropped. Used for the cases that
# must succeed -- the assertion is on the exact tag, so stderr is noise here.
#
# Usage: derive_tag <ref_type> <ref_name> <event_name> <dispatch_tag>
derive_tag() {
  env \
    GITHUB_REF_TYPE="$1" \
    GITHUB_REF_NAME="$2" \
    GITHUB_EVENT_NAME="$3" \
    PUBLISH_IMAGE_TAG="$4" \
    bash "${DERIVE}" 2>/dev/null
}

# Combined status + output, for the cases that must be refused. `env` pins the
# whole input set so a stray GITHUB_* from the surrounding CI cannot leak in.
#
# Usage: derive_run <ref_type> <ref_name> <event_name> <dispatch_tag>
derive_run() {
  run env \
    GITHUB_REF_TYPE="$1" \
    GITHUB_REF_NAME="$2" \
    GITHUB_EVENT_NAME="$3" \
    PUBLISH_IMAGE_TAG="$4" \
    bash "${DERIVE}"
}

# why: Guards `script/ci/derive_image_tag.sh`, which decides the GHCR image
# tag for the `publish-image` job (#66). The release/image pairing only
# holds because that tag is DERIVED from the git ref instead of typed in, so
# this is the table of refs a real push produces -- and the only part of the
# tag-triggered publish path provable without pushing a tag. The script is
# copied into the image at `/ci/` by the `devel-test` stage and run there.


# why: The deriver is actually shipped into the image at `/ci/`
@test "derive_image_tag: script is present and executable" {
  assert_file_exists "${DERIVE}"
  [ -x "${DERIVE}" ]
}

# why: The primary path: git ref -> image tag
@test "derive_image_tag: a release tag drops the v (v0.3.0 -> 0.3.0)" {
  [ "$(derive_tag tag v0.3.0 push '')" = '0.3.0' ]
}

# why: Pre-releases are first-class -- the rc is what gets verified
@test "derive_image_tag: an rc tag is preserved (v0.3.0-rc1 -> 0.3.0-rc1)" {
  [ "$(derive_tag tag v0.3.0-rc1 push '')" = '0.3.0-rc1' ]
}

# why: `v` is stripped, not required
@test "derive_image_tag: a tag without the v prefix still resolves" {
  [ "$(derive_tag tag 1.2.3 push '')" = '1.2.3' ]
}

# why: The escape hatch cannot override a tag -- that would BE the drift
@test "derive_image_tag: the git ref wins over a differing dispatch input" {
  # The escape hatch must not be able to override a tag ref -- that would be
  # exactly the release/image drift #66 closes.
  [ "$(derive_tag tag v0.3.0 workflow_dispatch 9.9.9)" = '0.3.0' ]
}

# why: The escape hatch works where there is no tag to derive from
@test "derive_image_tag: workflow_dispatch input is used off a branch" {
  [ "$(derive_tag branch main workflow_dispatch 0.3.0)" = '0.3.0' ]
}

# why: Typing `v0.3.0` in the box still yields `0.3.0`
@test "derive_image_tag: a v-prefixed dispatch input is tolerated" {
  [ "$(derive_tag branch main workflow_dispatch v0.3.0)" = '0.3.0' ]
}

# why: The workflow captures stdout verbatim; provenance stays on stderr
@test "derive_image_tag: the resolved tag is the only thing on stdout" {
  # The workflow captures stdout straight into the image tag, so provenance
  # and error chatter must never end up there.
  [ "$(derive_tag tag v0.3.0 push '' | wc -l)" -eq 1 ]
}

# why: The CI log records WHICH rule produced the tag
@test "derive_image_tag: provenance names the rule that fired" {
  derive_run tag v0.3.0 push ''
  assert_success
  assert_output --partial 'from git ref v0.3.0'
}

# why: Nothing publishes on a `main` push
@test "derive_image_tag: a plain main push publishes nothing" {
  derive_run branch main push ''
  assert_failure
  assert_output --partial 'no image tag to publish'
}

# why: An empty escape hatch is a no-op, not a guess
@test "derive_image_tag: a dispatch with an empty input publishes nothing" {
  derive_run branch main workflow_dispatch ''
  assert_failure
  assert_output --partial 'no image tag to publish'
}

# why: `vlatest` can no longer reach the workflow (the push trigger matches
# the version SHAPE, not `v*`), but the dispatch escape hatch types a
# version by hand and no glob sees it
@test "derive_image_tag: a non-version tag is refused, not published" {
  # This one can no longer reach the workflow -- the push trigger matches the
  # version SHAPE now, not `v*` -- but the rejection still has to hold here:
  # the workflow_dispatch escape hatch types a version by hand, and no glob
  # ever sees that value.
  derive_run tag vlatest push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}

# The refs that DO still slip past the trigger. GitHub's tag filters have no
# alternation and no anchored character classes, so the pre-release glob
# `v[0-9]+.[0-9]+.[0-9]+-*` accepts ANY suffix, including these. They reach the
# workflow and are stopped by its `verify-tag-shape` job, which runs this
# script before call-release cuts a Release and before the GPU job starts --
# so this is the assertion that job's correctness rests on.
# why: The refs that DO still slip past the trigger: GitHub's tag filters
# have no alternation or anchored classes, so `v[0-9]+.[0-9]+.[0-9]+-*`
# accepts `v1.2.3-`, `v1.2.3-rc_1`, `v1.2.3-rc1+b`. The `verify-tag-shape`
# job stops them by running this script before anything irreversible, so
# this is the assertion that job rests on
@test "derive_image_tag: a malformed pre-release suffix is refused" {
  derive_run tag v1.2.3-rc_1 push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'

  derive_run tag v1.2.3- push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'

  derive_run tag v1.2.3-rc1+b push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}

# why: `v0.3` is not MAJOR.MINOR.PATCH
@test "derive_image_tag: a truncated version tag is refused" {
  derive_run tag v0.3 push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}

# why: Same validation on the escape-hatch path
@test "derive_image_tag: a dispatch input that is not a version is refused" {
  derive_run branch main workflow_dispatch latest
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}
