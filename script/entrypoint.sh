#!/usr/bin/env bash
#
# Resolve the runtime stream config and render it into the served bundle.
#
# Pipeline (#17, S5): each app build injects up to three sentinels into its
# bundle (server / port / media) and preserves each sentinel-bearing chunk as
# a pristine *.js.tmpl. VIEWER_UI_MODE is an APP SELECTOR (D7): it picks which
# app's dist the entrypoint renders + serves (/app/usd-viewer/dist or
# /app/stream-only/dist), NOT a value rendered into a bundle. This entrypoint
# validates every operator-supplied value, then re-renders the ACTIVE app's
# *.js.tmpl -> *.js on EVERY boot. Re-rendering from the pristine template
# (rather than editing *.js in place) makes the substitution idempotent: a
# `docker restart` or a changed env / host.yaml is picked up on the next start
# instead of reusing the first-boot values. The per-app sentinel set differs
# (usd-viewer carries server/port only; stream-only also carries media), so a
# sed for a sentinel a given app never emitted is a harmless no-op.
#
# Strict mode is the documented contract for the logging helper, which is
# `set -u` safe, so we enable it before sourcing.
set -euo pipefail

# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by the Dockerfile's
# build/runtime/devel stages (refs base#328 + base#368).
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
# viewer.ui_mode follows the same precedence as public_ip: host.yaml
# viewer.ui_mode > VIEWER_UI_MODE env > built-in default. A host.yaml
# with only a network section leaves the viewer value untouched
# (back-compat). Ports (SIGNALING_PORT / MEDIA_PORT / SERVE_PORT) are
# workload runtime params delivered via env/.env (D8), NOT host.yaml.
if [ -f /etc/host.yaml ]; then
  host_ip="$(yaml_value public_ip /etc/host.yaml)"
  if [ -n "${host_ip}" ]; then SIGNALING_SERVER="${host_ip}"; fi

  yaml_ui_mode="$(yaml_value ui_mode /etc/host.yaml)"
  if [ -n "${yaml_ui_mode}" ]; then VIEWER_UI_MODE="${yaml_ui_mode}"; fi
fi

# Resolve final values (built-in defaults). MEDIA_PORT has NO default:
# unset = the library negotiates media via SDP (D1 back-compat).
SIGNALING_SERVER="${SIGNALING_SERVER:-127.0.0.1}"
SIGNALING_PORT="${SIGNALING_PORT:-49100}"
VIEWER_UI_MODE="${VIEWER_UI_MODE:-usd-viewer}"

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
# MEDIA_PORT is OPTIONAL (D1): unset -> rendered as the literal `null`
# (the stream-only app omits mediaPort and the library SDP-negotiates).
# When set it must be an integer 1..65535.
if [ -n "${MEDIA_PORT:-}" ]; then
  if [[ ! "${MEDIA_PORT}" =~ ^[0-9]+$ ]] || \
     [ "${MEDIA_PORT}" -lt 1 ] || [ "${MEDIA_PORT}" -gt 65535 ]; then
    echo "entrypoint: invalid media port '${MEDIA_PORT}'" \
         "(must be an integer 1..65535, or unset to negotiate)" >&2
    exit 1
  fi
  media_value="${MEDIA_PORT}"
else
  media_value="null"
fi

# VIEWER_UI_MODE selects which app dist to render + serve (D7); the CMD
# reads the same resolved value via ${VIEWER_UI_MODE}, so export it.
export VIEWER_UI_MODE
assets_dir="/app/${VIEWER_UI_MODE}/dist/assets"

# Render every pristine template -> served *.js for the ACTIVE app only.
# nullglob so a missing template set yields an empty array (caught below)
# instead of the literal glob pattern.
shopt -s nullglob
templates=("${assets_dir}"/*.js.tmpl)
if [ "${#templates[@]}" -eq 0 ]; then
  echo "entrypoint: no ${assets_dir}/*.js.tmpl found;" \
       "cannot render stream config for ui_mode '${VIEWER_UI_MODE}'" >&2
  exit 1
fi
for tmpl in "${templates[@]}"; do
  out="${tmpl%.tmpl}"
  # Render to a temp file then atomically swap, so a partial sed never
  # leaves a half-written bundle being served. The media sed is a no-op
  # where the sentinel is absent (e.g. usd-viewer).
  sed \
    -e "s|__OWV_SERVER__|${SIGNALING_SERVER}|g" \
    -e "s|\"__OWV_PORT__\"|${SIGNALING_PORT}|g" \
    -e "s|\"__OWV_MEDIA_PORT__\"|${media_value}|g" \
    "${tmpl}" > "${out}.rendering"
  mv -- "${out}.rendering" "${out}"
done

exec "${@}"
