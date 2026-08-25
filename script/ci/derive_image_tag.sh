#!/usr/bin/env bash
#
# derive_image_tag.sh -- resolve the GHCR image tag for a publish run (#66).
#
# The whole point of #66 is that a single git tag emits a GitHub Release AND a
# GHCR image whose version strings MATCH, so the two are traceable in both
# directions. That only holds if the image tag is DERIVED from the git ref
# rather than typed in by hand, so this script -- not a human -- decides it.
#
# Resolution order (the git ref WINS; see "Why the ref wins" below):
#   1. GITHUB_REF_TYPE == "tag"  ->  GITHUB_REF_NAME with any leading "v"
#      stripped.  v0.3.0 -> 0.3.0,  v0.3.0-rc1 -> 0.3.0-rc1.
#   2. else, on workflow_dispatch, a non-empty PUBLISH_IMAGE_TAG input (also
#      "v"-tolerant, so a maintainer typing `v0.3.0` gets `0.3.0`).
#   3. else, hard error -- there is nothing to publish and guessing would
#      produce exactly the drift this exists to prevent.
#
# Why the ref wins over the dispatch input: on a tag ref the ref IS the
# authoritative version, and honouring a differing hand-typed value there would
# reintroduce the drift #66 closes. The input is the escape hatch for the case
# where there is no tag ref to derive from (a manual publish off a branch), not
# an override of a tag.
#
# Pre-release tags are first-class: the rc is what gets verified before the
# final tag is cut, so `v0.3.0-rc1` must produce a matching `:0.3.0-rc1` image.
#
# The accepted shape is semver-ish -- MAJOR.MINOR.PATCH with an optional
# pre-release suffix. A ref that does not match is a hard failure rather than a
# best-effort publish: `.github/workflows/main.yaml` triggers on `v*`, so a
# stray non-version tag would otherwise push a garbage image tag that a
# consumer could pin and that nothing would ever supersede.
#
# Env (all read from the GitHub Actions context; overridable for testing):
#   GITHUB_REF_TYPE      "tag" | "branch"
#   GITHUB_REF_NAME      short ref name (e.g. v0.3.0)
#   GITHUB_EVENT_NAME    triggering event (e.g. push, workflow_dispatch)
#   PUBLISH_IMAGE_TAG    workflow_dispatch escape-hatch input (may be empty)
#
# Writes the resolved tag to stdout and a one-line provenance note to stderr,
# so the CI log records WHICH rule fired. Exits non-zero with an
# ::error:: annotation when no tag can be resolved.

set -euo pipefail

readonly VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([0-9A-Za-z.-]*[0-9A-Za-z])?)?$'

# Emits a GitHub Actions error annotation and exits non-zero. The message is
# kept on ONE line: a `::error::` workflow command ends at the newline, so a
# wrapped message would silently drop everything after the first line out of
# the annotation.
#
# Globals:
#   None
# Arguments:
#   $1: message
# Outputs:
#   Writes the annotation to stderr.
_die() {
  echo "::error::derive_image_tag: $1" >&2
  exit 1
}

main() {
  local ref_type="${GITHUB_REF_TYPE:-}"
  local ref_name="${GITHUB_REF_NAME:-}"
  local event_name="${GITHUB_EVENT_NAME:-}"
  local dispatch_tag="${PUBLISH_IMAGE_TAG:-}"

  local tag=""
  local tag_source=""

  if [[ "${ref_type}" == "tag" && -n "${ref_name}" ]]; then
    tag="${ref_name#v}"
    tag_source="git ref ${ref_name}"
  elif [[ "${event_name}" == "workflow_dispatch" && -n "${dispatch_tag}" ]]; then
    tag="${dispatch_tag#v}"
    tag_source="workflow_dispatch input"
  else
    _die "no image tag to publish -- this run is neither a tag ref nor a workflow_dispatch carrying a publish_image_tag input"
  fi

  if [[ ! "${tag}" =~ ${VERSION_RE} ]]; then
    _die "'${tag}' (from ${tag_source}) is not a MAJOR.MINOR.PATCH[-PRERELEASE] version; refusing to publish an image tag no release can be matched to"
  fi

  echo "derive_image_tag: ${tag} (from ${tag_source})" >&2
  echo "${tag}"
}

main "$@"
