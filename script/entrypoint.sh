#!/usr/bin/env bash
#
# Resolve the runtime stream config and render it into the served bundle.
#
# Pipeline (#17): the build injects four sentinels into the bundle and
# preserves each sentinel-bearing chunk as a pristine *.js.tmpl. This
# entrypoint validates every operator-supplied value, then re-renders
# *.js.tmpl -> *.js on EVERY boot. Re-rendering from the pristine
# template (rather than editing *.js in place) makes the substitution
# idempotent: a `docker restart` or a changed env / host.yaml is picked
# up on the next start instead of reusing the first-boot values.
#
# Strict mode is the documented contract for the logging helper, which is
# `set -u` safe, so we enable it before sourcing.
set -euo pipefail

# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by the Dockerfile's
# devel + example stages (refs base#328 + base#368).
# shellcheck source=/dev/null
. /usr/local/lib/base/logging.sh

# yaml_value <key> <file>: extract a scalar value for a top-level-ish
# `<key>: <value>` line. Strips surrounding quotes, a trailing inline
# `# comment`, and trailing whitespace. Prints nothing if absent.
yaml_value() {
  awk -F': *' -v key="$1" '
    $0 ~ "^[[:space:]]*" key ":" {
      v = $2
      sub(/[[:space:]]*#.*$/, "", v)   # drop inline comment
      gsub(/"/, "", v)                 # drop quotes
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$2" 2>/dev/null || true
}

# Per-host config (mounted by caller from config/host.yaml). When
# present, network.public_ip overrides the SIGNALING_SERVER env var --
# keeps a single source of truth for the host IP across all containers
# that read the same yaml (e.g. ycpss91255-docker/isaac#65).
# viewer.ui_mode / viewer.auto_launch follow the same precedence as
# public_ip: host.yaml viewer.* > VIEWER_* env > built-in default. A
# host.yaml with only a network section leaves the viewer values
# untouched (back-compat).
if [ -f /etc/host.yaml ]; then
  host_ip="$(yaml_value public_ip /etc/host.yaml)"
  if [ -n "${host_ip}" ]; then SIGNALING_SERVER="${host_ip}"; fi

  yaml_ui_mode="$(yaml_value ui_mode /etc/host.yaml)"
  if [ -n "${yaml_ui_mode}" ]; then VIEWER_UI_MODE="${yaml_ui_mode}"; fi

  yaml_auto_launch="$(yaml_value auto_launch /etc/host.yaml)"
  if [ -n "${yaml_auto_launch}" ]; then VIEWER_AUTO_LAUNCH="${yaml_auto_launch}"; fi
fi

# Resolve final values (built-in defaults).
SIGNALING_SERVER="${SIGNALING_SERVER:-127.0.0.1}"
SIGNALING_PORT="${SIGNALING_PORT:-49100}"
VIEWER_UI_MODE="${VIEWER_UI_MODE:-usd-viewer}"
VIEWER_AUTO_LAUNCH="${VIEWER_AUTO_LAUNCH:-false}"

# Validate before substituting. Each value lands in a browser-executed
# JS bundle via sed, so a bad value must fail the container fast rather
# than bake malformed JS or inject sed/JS metacharacters. The charset /
# enum whitelists below also guarantee no sed replacement metacharacter
# (| & \ newline) can survive -- validation IS the escaping.
if [[ ! "${SIGNALING_SERVER}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "entrypoint: invalid signaling server '${SIGNALING_SERVER}'" \
       "(allowed: hostname / IPv4 chars A-Za-z0-9.-)" >&2
  exit 1
fi
if [[ ! "${SIGNALING_PORT}" =~ ^[0-9]+$ ]]; then
  echo "entrypoint: invalid signaling port '${SIGNALING_PORT}' (must be numeric)" >&2
  exit 1
fi
case "${VIEWER_UI_MODE}" in
  usd-viewer | stream-only) ;;
  *)
    echo "entrypoint: invalid ui_mode '${VIEWER_UI_MODE}'" \
         "(expected usd-viewer | stream-only)" >&2
    exit 1
    ;;
esac
case "${VIEWER_AUTO_LAUNCH}" in
  true | false) ;;
  *)
    echo "entrypoint: invalid auto_launch '${VIEWER_AUTO_LAUNCH}'" \
         "(expected true | false)" >&2
    exit 1
    ;;
esac

# Render every pristine template -> served *.js. nullglob so a missing
# template set yields an empty array (caught below) instead of the
# literal glob pattern.
shopt -s nullglob
templates=(/app/dist/assets/*.js.tmpl)
if [ "${#templates[@]}" -eq 0 ]; then
  echo "entrypoint: no /app/dist/assets/*.js.tmpl found;" \
       "cannot render stream config" >&2
  exit 1
fi
for tmpl in "${templates[@]}"; do
  out="${tmpl%.tmpl}"
  # Render to a temp file then atomically swap, so a partial sed never
  # leaves a half-written bundle being served.
  sed \
    -e "s|__OWV_SERVER__|${SIGNALING_SERVER}|g" \
    -e "s|\"__OWV_PORT__\"|${SIGNALING_PORT}|g" \
    -e "s|__OWV_UI_MODE__|${VIEWER_UI_MODE}|g" \
    -e "s|\"__OWV_AUTOLAUNCH__\"|${VIEWER_AUTO_LAUNCH}|g" \
    "${tmpl}" > "${out}.rendering"
  mv -- "${out}.rendering" "${out}"
done

exec "${@}"
