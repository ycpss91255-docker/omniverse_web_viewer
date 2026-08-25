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

@test "derive_image_tag: script is present and executable" {
  assert_file_exists "${DERIVE}"
  [ -x "${DERIVE}" ]
}

@test "derive_image_tag: a release tag drops the v (v0.3.0 -> 0.3.0)" {
  [ "$(derive_tag tag v0.3.0 push '')" = '0.3.0' ]
}

@test "derive_image_tag: an rc tag is preserved (v0.3.0-rc1 -> 0.3.0-rc1)" {
  [ "$(derive_tag tag v0.3.0-rc1 push '')" = '0.3.0-rc1' ]
}

@test "derive_image_tag: a tag without the v prefix still resolves" {
  [ "$(derive_tag tag 1.2.3 push '')" = '1.2.3' ]
}

@test "derive_image_tag: the git ref wins over a differing dispatch input" {
  # The escape hatch must not be able to override a tag ref -- that would be
  # exactly the release/image drift #66 closes.
  [ "$(derive_tag tag v0.3.0 workflow_dispatch 9.9.9)" = '0.3.0' ]
}

@test "derive_image_tag: workflow_dispatch input is used off a branch" {
  [ "$(derive_tag branch main workflow_dispatch 0.3.0)" = '0.3.0' ]
}

@test "derive_image_tag: a v-prefixed dispatch input is tolerated" {
  [ "$(derive_tag branch main workflow_dispatch v0.3.0)" = '0.3.0' ]
}

@test "derive_image_tag: the resolved tag is the only thing on stdout" {
  # The workflow captures stdout straight into the image tag, so provenance
  # and error chatter must never end up there.
  [ "$(derive_tag tag v0.3.0 push '' | wc -l)" -eq 1 ]
}

@test "derive_image_tag: provenance names the rule that fired" {
  derive_run tag v0.3.0 push ''
  assert_success
  assert_output --partial 'from git ref v0.3.0'
}

@test "derive_image_tag: a plain main push publishes nothing" {
  derive_run branch main push ''
  assert_failure
  assert_output --partial 'no image tag to publish'
}

@test "derive_image_tag: a dispatch with an empty input publishes nothing" {
  derive_run branch main workflow_dispatch ''
  assert_failure
  assert_output --partial 'no image tag to publish'
}

@test "derive_image_tag: a non-version tag is refused, not published" {
  # `on: push: tags: ['v*']` would happily fire for this.
  derive_run tag vlatest push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}

@test "derive_image_tag: a truncated version tag is refused" {
  derive_run tag v0.3 push ''
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}

@test "derive_image_tag: a dispatch input that is not a version is refused" {
  derive_run branch main workflow_dispatch latest
  assert_failure
  assert_output --partial 'is not a MAJOR.MINOR.PATCH'
}
