#!/usr/bin/env bash
# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by Dockerfile.example's
# devel stage (refs #364 + #368).
. /usr/local/lib/base/_entrypoint_logging.sh

for js in /app/dist/assets/*.js; do
  [ -f "${js}" ] || continue
  sed -i \
    -e "s|__OWV_SERVER__|${SIGNALING_SERVER:-127.0.0.1}|g" \
    -e "s|\"__OWV_PORT__\"|${SIGNALING_PORT:-49100}|g" \
    "${js}"
done

exec "${@}"
