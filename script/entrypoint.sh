#!/usr/bin/env bash
# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by Dockerfile.example's
# devel stage (refs #364 + #368).
. /usr/local/lib/base/_entrypoint_logging.sh

# Per-host config (mounted by caller from config/host.yaml). When
# present, network.public_ip overrides the SIGNALING_SERVER env var —
# keeps a single source of truth for the host IP across all containers
# that read the same yaml (e.g. ycpss91255-docker/isaac#65).
# viewer.ui_mode / viewer.auto_launch follow the same precedence as
# public_ip: host.yaml viewer.* > VIEWER_* env > built-in default (the
# ${VAR:-default} expansions below). A host.yaml with only a network
# section leaves the viewer defaults untouched (back-compat).
if [ -f /etc/host.yaml ]; then
  HOST_IP=$(awk -F': *' '/^[[:space:]]*public_ip:/{gsub(/"/,""); print $2}' \
    /etc/host.yaml 2>/dev/null || true)
  [ -n "${HOST_IP}" ] && SIGNALING_SERVER="${HOST_IP}"

  YAML_UI_MODE=$(awk -F': *' '/^[[:space:]]*ui_mode:/{gsub(/"/,""); print $2}' \
    /etc/host.yaml 2>/dev/null || true)
  [ -n "${YAML_UI_MODE}" ] && VIEWER_UI_MODE="${YAML_UI_MODE}"

  YAML_AUTO_LAUNCH=$(awk -F': *' '/^[[:space:]]*auto_launch:/{gsub(/"/,""); print $2}' \
    /etc/host.yaml 2>/dev/null || true)
  [ -n "${YAML_AUTO_LAUNCH}" ] && VIEWER_AUTO_LAUNCH="${YAML_AUTO_LAUNCH}"
fi

for js in /app/dist/assets/*.js; do
  [ -f "${js}" ] || continue
  sed -i \
    -e "s|__OWV_SERVER__|${SIGNALING_SERVER:-127.0.0.1}|g" \
    -e "s|\"__OWV_PORT__\"|${SIGNALING_PORT:-49100}|g" \
    -e "s|__OWV_UI_MODE__|${VIEWER_UI_MODE:-usd-viewer}|g" \
    -e "s|\"__OWV_AUTOLAUNCH__\"|${VIEWER_AUTO_LAUNCH:-false}|g" \
    "${js}"
done

exec "${@}"
