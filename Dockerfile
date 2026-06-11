ARG BASE_IMAGE="ubuntu:24.04"
ARG TEST_TOOLS_IMAGE="test-tools:local"

############################## sys ##############################
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS sys

ARG USER_NAME="user"
ARG USER_GID=1000
ARG USER_UID=1000
ARG USER_GROUP="user"
ARG TZ="Asia/Taipei"
ARG APT_MIRROR_UBUNTU="tw.archive.ubuntu.com"
ARG DEBIAN_FRONTEND=noninteractive

# Requires BASE_IMAGE to provide /bin/bash (true for the default ubuntu:24.04
# and any debian-family base). This SHELL is set before the first RUN, so bash
# cannot be installed first — overriding BASE_IMAGE to a bash-less base (e.g.
# alpine/busybox) requires changing this line too.
SHELL ["/bin/bash", "-x", "-euo", "pipefail", "-c"]

RUN sed -i "s@archive.ubuntu.com@${APT_MIRROR_UBUNTU}@g" /etc/apt/sources.list || true; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        tzdata \
        locales \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG="en_US.UTF-8" && \
    ln -snf /usr/share/zoneinfo/"${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV TZ="${TZ}"

RUN if getent group "${USER_GID}" >/dev/null; then \
        groupmod -n "${USER_GROUP}" "$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${USER_GID}" "${USER_GROUP}"; \
    fi && \
    if getent passwd "${USER_UID}" >/dev/null; then \
        usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m \
            "$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
    else \
        useradd -m -l -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"; \
    fi && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

############################## devel-base ##############################
FROM sys AS devel-base

ARG DEBIAN_FRONTEND=noninteractive

# DL4006: the bash SHELL with pipefail set in the sys stage carries over
# via FROM (image config); hadolint just doesn't track SHELL across stages.
# hadolint ignore=DL4006
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sudo \
        git \
        curl \
        ca-certificates \
        && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g serve@14.2.6 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## usd-viewer-build ##############################
# Build the upstream web-viewer-sample (the `src/` submodule) UNMODIFIED (D2):
# no App.tsx fork. Only overlay/stream.config.json is layered (a supported
# config override, not a code patch) carrying the server/port sentinels the
# entrypoint renders at boot. The resulting dist is staged at
# /app/usd-viewer/dist so the lean runtime COPYs it to the same path the
# uniform entrypoint serves (/app/${VIEWER_UI_MODE}/dist). No __OWV_MEDIA_PORT__
# sentinel here -- usd-viewer keeps upstream's native SDP media negotiation
# (D1 back-compat default).
FROM devel-base AS usd-viewer-build

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"

USER "${USER}"
ENV HOME="/home/${USER_NAME}"

COPY --chown="${USER}":"${GROUP}" src/package.json src/.npmrc /app/
WORKDIR /app
RUN npm install

COPY --chown="${USER}":"${GROUP}" src/ /app/
COPY --chown="${USER}":"${GROUP}" overlay/stream.config.json /app/stream.config.json
RUN sed -i 's|"server":.*|"server": "__OWV_SERVER__",|' stream.config.json && \
    sed -i 's|"signalingPort":.*|"signalingPort": "__OWV_PORT__",|' stream.config.json && \
    npm run build && \
    for f in dist/assets/*.js; do \
        if grep -q '__OWV_' "${f}"; then cp -- "${f}" "${f}.tmpl"; fi; \
    done && \
    test -n "$(ls dist/assets/*.js.tmpl 2>/dev/null)" && \
    sudo mkdir -p /app/usd-viewer && sudo mv /app/dist /app/usd-viewer/dist && \
    sudo chown -R "${USER}":"${GROUP}" /app/usd-viewer
# (path arranged above: built dist staged at /app/usd-viewer/dist via sudo so
# the build stays as the non-root USER -- runtime COPYs it to the served path.)

############################## stream-only-build ##############################
# Build OUR OWN full-screen stream-only app (apps/stream-only) over stream-core
# inside the npm workspace (D2/D3). The whole workspace must be present so the
# app resolves its sibling `stream-core` dep; an isolated per-app install can't.
# streamTarget.json carries all 3 sentinels (server / port / media); media
# (__OWV_MEDIA_PORT__) is the stream-only app's knob (D1). Output staged at
# /app/stream-only/dist for the runtime COPY.
FROM devel-base AS stream-only-build

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"

USER "${USER}"
ENV HOME="/home/${USER_NAME}"

WORKDIR /build
COPY --chown="${USER}":"${GROUP}" package.json .npmrc /build/
COPY --chown="${USER}":"${GROUP}" packages/stream-core /build/packages/stream-core
COPY --chown="${USER}":"${GROUP}" apps/stream-only /build/apps/stream-only
RUN npm install && \
    npm -w stream-core test && \
    npm -w stream-only run lint && \
    npm -w stream-only test && \
    npm -w stream-only run build && \
    for f in apps/stream-only/dist/assets/*.js; do \
        if grep -q '__OWV_' "${f}"; then cp -- "${f}" "${f}.tmpl"; fi; \
    done && \
    test -n "$(ls apps/stream-only/dist/assets/*.js.tmpl 2>/dev/null)" && \
    sudo mkdir -p /app/stream-only && \
    sudo mv /build/apps/stream-only/dist /app/stream-only/dist && \
    sudo chown -R "${USER}":"${GROUP}" /app/stream-only

############################## runtime ##############################
# LEAN deployed image (replaces the old `serve = FROM devel`). FROM devel-base
# for node + serve only -- NO npm install, NO src/ submodule, NO node_modules,
# NO build toolchain. Both built dists are COPY'd in from the build stages so
# the uniform entrypoint can serve either app by VIEWER_UI_MODE. This is the
# image Isaac runs (omniverse_web_viewer:runtime).
FROM devel-base AS runtime

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
# Host-side log tee helper (base#328 / base#368). No-op when [logging]
# local_path is unset; sourced unconditionally by script/entrypoint.sh.
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh

# Both app dists at the path the entrypoint serves: /app/<mode>/dist.
COPY --from=usd-viewer-build --chown="${USER}":"${GROUP}" /app/usd-viewer/dist /app/usd-viewer/dist
COPY --from=stream-only-build --chown="${USER}":"${GROUP}" /app/stream-only/dist /app/stream-only/dist

USER "${USER}"
ENV HOME="/home/${USER_NAME}"

# Interim runtime ENV defaults (until Phase-2 base-A2 .env). MEDIA_PORT has
# NO default: unset = null = the library negotiates media via SDP (D1).
ENV SIGNALING_SERVER="127.0.0.1"
ENV SIGNALING_PORT="49100"
ENV SERVE_PORT="5173"
ENV VIEWER_UI_MODE="usd-viewer"

WORKDIR "${HOME}/work"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sh", "-c", "serve -s /app/${VIEWER_UI_MODE}/dist -l ${SERVE_PORT}"]

############################## devel ##############################
# Interactive dev image: full toolchain + sources for building in place, PLUS
# both built dists COPY'd from the build stages so the uniform entrypoint
# (which targets /app/<mode>/dist) works here too. devel-test (FROM devel) thus
# has /app/usd-viewer/dist + /app/stream-only/dist present for the bats to
# exercise the render path.
FROM devel-base AS devel

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
ARG CONFIG_SRC="config"

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"

USER "${USER}"

ENV HOME="/home/${USER_NAME}"

# Shell setup per Dockerfile.example's devel stage, minus the
# terminator/tmux setup.sh calls: this trimmed devel-base ships
# neither binary (node/serve image), and those scripts hard-fail
# their check_deps when the tool is absent.
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    sudo rm -rf "${CONFIG_DIR}"

# Full workspace + upstream submodule for in-place dev builds.
COPY --chown="${USER}":"${GROUP}" src/package.json src/.npmrc /app/
WORKDIR /app
RUN npm install

COPY --chown="${USER}":"${GROUP}" src/ /app/
COPY --chown="${USER}":"${GROUP}" overlay/stream.config.json /app/stream.config.json

# Both built dists present so the uniform entrypoint (/app/<mode>/dist) works
# in devel and devel-test exactly as it does in runtime.
COPY --from=usd-viewer-build --chown="${USER}":"${GROUP}" /app/usd-viewer/dist /app/usd-viewer/dist
COPY --from=stream-only-build --chown="${USER}":"${GROUP}" /app/stream-only/dist /app/stream-only/dist

WORKDIR "${HOME}/work"

ENV SIGNALING_SERVER="127.0.0.1"
ENV SIGNALING_PORT="49100"
ENV SERVE_PORT="5173"
ENV VIEWER_UI_MODE="usd-viewer"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sh", "-c", "serve -s /app/${VIEWER_UI_MODE}/dist -l ${SERVE_PORT}"]

############################## runtime-test ##############################
# Install-check smoke for the LEAN runtime image. Mirrors `FROM devel AS
# devel-test` -- ephemeral, build-only, never pushed. CI builds this target
# after `target: runtime` (gated by build_runtime: true); build failure
# surfaces a smoke failure in the GHA log.
#
# Strong baked default: prove the production image actually serves BOTH app
# modes. Background `serve` on each dist on a spare port, curl both for HTTP
# 200, exit 0/1. Override per repo via build_args: RUNTIME_SMOKE_CMD=<command>.
#
# `bash -c` wrapper required: `RUN ${ARG}` word-splits the value and treats
# shell operators as literal args; wrapping passes it as one string for bash
# to parse (preserving &&, ||, nested quotes, parameter expansion). See
# Dockerfile.example ~lines 387-399.
FROM runtime AS runtime-test

# hadolint ignore=SC2016
ARG RUNTIME_SMOKE_CMD='timeout 30 bash -c '"'"'serve -s /app/usd-viewer/dist -l 5173 & serve -s /app/stream-only/dist -l 5174 & for _ in $(seq 1 30); do if curl -fsS http://127.0.0.1:5173 >/dev/null 2>&1 && curl -fsS http://127.0.0.1:5174 >/dev/null 2>&1; then exit 0; fi; sleep 0.5; done; exit 1'"'"''
# Inherit USER from runtime (non-root). The smoke does not need privilege.
RUN bash -c "${RUNTIME_SMOKE_CMD}"

############################## example ##############################
# Embeddable stream demo site (examples/embedded-site-demo). Vanilla
# TS + Vite, served on EXAMPLE_PORT (8080) -- independent of the main
# viewer so both can run at once. Reuses the same entrypoint, serving the
# example bundle under the usd-viewer mode dir. Closes #15.
FROM devel-base AS example

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
# Same log tee helper as the runtime/devel stages: this stage builds from
# devel-base, so those COPYs are not inherited and must be repeated.
COPY --chmod=0755 .base/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh

USER "${USER}"
ENV HOME="/home/${USER_NAME}"

WORKDIR /app
# Workspace-aware build: the example imports its sibling `stream-core`, so the
# whole npm workspace must be present and installed at the root (an isolated
# install of only the example can no longer resolve stream-core). The built
# example dist is served via the usd-viewer mode dir so the generic entrypoint
# renders it (VIEWER_UI_MODE=usd-viewer).
COPY --chown="${USER}":"${GROUP}" package.json .npmrc /app/
COPY --chown="${USER}":"${GROUP}" packages/stream-core /app/packages/stream-core
COPY --chown="${USER}":"${GROUP}" examples/embedded-site-demo /app/examples/embedded-site-demo
RUN npm install && \
    npm -w stream-core test && \
    npm -w embedded-site-demo run lint && \
    npm -w embedded-site-demo test && \
    npm -w embedded-site-demo run build && \
    mkdir -p /app/usd-viewer && \
    cp -r examples/embedded-site-demo/dist /app/usd-viewer/dist && \
    for f in /app/usd-viewer/dist/assets/*.js; do \
        if grep -q '__OWV_' "${f}"; then cp -- "${f}" "${f}.tmpl"; fi; \
    done && \
    test -n "$(ls /app/usd-viewer/dist/assets/*.js.tmpl 2>/dev/null)"
# Smoke: the static server answers 200 on 8080 (pre-render bundle is fine).
# Run in a bounded inner shell that backgrounds serve and exits as soon as a
# request succeeds; the build step tears the backgrounded server down on exit.
# SC2016: the $ expressions are meant for the inner `bash -c`, not the outer shell.
# hadolint ignore=SC2016
RUN timeout 30 bash -c 'serve -s /app/usd-viewer/dist -l 8080 & \
    for _ in $(seq 1 30); do \
        curl -fsS http://127.0.0.1:8080 >/dev/null 2>&1 && exit 0; \
        sleep 0.5; \
    done; \
    exit 1'

WORKDIR "${HOME}/work"

ENV SIGNALING_SERVER="127.0.0.1"
ENV SIGNALING_PORT="49100"
ENV EXAMPLE_PORT="8080"
ENV VIEWER_UI_MODE="usd-viewer"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sh", "-c", "serve -s /app/${VIEWER_UI_MODE}/dist -l ${EXAMPLE_PORT}"]

############################## devel-test ##############################
# Resolves to test-tools:local (local build.sh) or ghcr.io/.../test-tools:vX.Y.Z (CI).
# hadolint ignore=DL3006
FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage

FROM devel AS devel-test

USER root

COPY --from=test-tools-stage /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=test-tools-stage /usr/local/bin/hadolint /usr/local/bin/hadolint

COPY .hadolint.yaml /lint/.hadolint.yaml
COPY Dockerfile /lint/Dockerfile
# script/*.sh = repo entrypoint.sh + the wrapper symlinks (BuildKit
# dereferences them; the targets live inside the build context).
COPY script/*.sh /lint/
# base#406: all helper libs (_lib.sh, i18n.sh, _tui_conf.sh, ...) now
# live under lib/; the wrappers themselves under wrapper/.
COPY .base/script/docker/lib /lint/lib
COPY .base/script/docker/wrapper /lint/wrapper
# /lint/*.sh keeps our loose files (script/entrypoint.sh) covered on
# top of the template's wrapper + lib coverage.
RUN shellcheck -S warning /lint/*.sh /lint/wrapper/*.sh /lint/lib/*.sh
WORKDIR /lint
RUN hadolint Dockerfile

COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/bats/ /smoke_test/

# Example source is checked by example_demo.bats (contract + node --test);
# the full example build (lint / vite / serve smoke) runs in the `example`
# stage above.
COPY examples/ /examples/

ARG USER
USER "${USER}"

RUN bats /smoke_test/
