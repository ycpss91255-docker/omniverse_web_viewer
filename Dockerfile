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
    fi

# NOTE: `sys` deliberately grants NO sudo. It used to end with
# `echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers`, and since
# `runtime` is FROM devel-base is FROM sys, that line was INHERITED BY THE
# PUBLISHED IMAGE -- making its "non-root" USER root-equivalent with a single
# `sudo`, on an image that is pushed publicly to GHCR, pinned by downstream
# consumers (isaac#173), and run there on a network port with --network=host.
# The non-root USER is the containment story for that exposure; nothing in the
# runtime needs privilege (see the runtime-test guard at the bottom of this
# file). The grant now lives ONLY in the stages that actually use it --
# usd-viewer-build, stream-only-build and devel -- all of which are either
# discarded after their build or interactive-only.

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

# Per-stage sudo grant (see the note in `sys`): this stage stages its dist
# under /app with sudo so the build itself stays as the non-root USER. The
# stage is discarded once `runtime` has COPY'd the dist out of it.
RUN echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER_NAME}" && \
    chmod 0440 "/etc/sudoers.d/${USER_NAME}"

USER "${USER}"
ENV HOME="/home/${USER_NAME}"

COPY --chown="${USER}":"${GROUP}" src/package.json src/.npmrc /app/
WORKDIR /app
# `npm install`, NOT `npm ci`: this tree is the upstream web-viewer-sample
# submodule, which ships no package-lock.json, and D2 says it is built
# UNMODIFIED. Our own code is installed with `npm ci` from a committed lockfile
# (stream-only-build / example / e2e-test); this one stage's dependency tree is
# still resolved fresh on every build. Closing that needs either an upstream
# lockfile or a decision to layer one of ours onto the sample.
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

# Per-stage sudo grant (see the note in `sys`): same reason as
# usd-viewer-build, and this stage is likewise discarded after the dist COPY.
RUN echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER_NAME}" && \
    chmod 0440 "/etc/sudoers.d/${USER_NAME}"

USER "${USER}"
ENV HOME="/home/${USER_NAME}"

WORKDIR /build
COPY --chown="${USER}":"${GROUP}" package.json package-lock.json .npmrc /build/
COPY --chown="${USER}":"${GROUP}" packages/stream-core /build/packages/stream-core
COPY --chown="${USER}":"${GROUP}" apps/stream-only /build/apps/stream-only
# `npm ci`, not `npm install`: the bundle this stage emits is what ships in the
# public image, so the tree that produces it must be the COMMITTED one, not
# whatever the ranges resolve to today. `npm ci` also fails loudly on lock drift
# instead of silently rewriting the lockfile. The workspace is deliberately
# PARTIAL here (no examples/) and npm ci simply skips the absent member.
RUN npm ci && \
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
# LEAN deployed image (replaces the old `serve = FROM devel`). This is the image
# Isaac runs (omniverse_web_viewer:runtime) and the one published to GHCR.
#
# WHAT IT ACTUALLY SHIPS, stated exactly, because the previous wording ("node +
# serve only ... NO build toolchain") was not true of the built image and
# ADR-0001 repeated the claim: `devel-base` apt-installs sudo/git/curl and the
# nodejs deb brings npm + corepack along with node, and ALL of that was
# inherited here. What ships now is node + serve + curl + the two built dists,
# and nothing else from the build:
#   - npm / npx / corepack are DELETED. They are only reachable via node's own
#     package tree, never installed by apt, so they have to be removed rather
#     than not-installed;
#   - git and sudo are PURGED. Nothing in the runtime, or in any stage built
#     FROM it, uses either;
#   - curl STAYS, deliberately. It is the HTTP client the two FROM-runtime test
#     stages use -- runtime-test's RUNTIME_SMOKE_CMD and test/e2e/run-in-image.sh
#     -- and removing it while `node` (which has global fetch) remains would buy
#     no real containment, only a rewrite of that contract.
# Also: NO src/ submodule, NO app node_modules, NO source tree.
#
# Removed HERE rather than never-installed because devel-base must have curl to
# fetch nodesource, and the two build stages need the toolchain; this stage is
# the first point downstream of them where the deployable set is knowable.
FROM devel-base AS runtime

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"

# First layer of the stage, so it caches independently of the dists below.
# SUDO_FORCE_REMOVE: sudo's prerm refuses to uninstall itself when no root
# password is set, on the reasoning that an interactive host would lock itself
# out of administration. For a single-purpose container image with no root
# password and no administrator, having no path to root is the goal, not the
# accident it warns about.
RUN SUDO_FORCE_REMOVE=yes apt-get purge -y git sudo && \
    rm -rf /usr/lib/node_modules/npm /usr/lib/node_modules/corepack \
           /usr/bin/npm /usr/bin/npx /usr/bin/corepack && \
    rm -rf /var/lib/apt/lists/*

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

# Per-stage sudo grant (see the note in `sys`). Passwordless sudo in an
# INTERACTIVE dev container is by design (it is why .hadolint.yaml ignores
# DL3004); the defect was that `sys` handed the same grant to the published
# runtime image. devel needs it for `sudo rm -rf "${CONFIG_DIR}"` below, and
# devel-test (FROM devel) needs it for the bats specs that write /etc/host.yaml.
RUN echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER_NAME}" && \
    chmod 0440 "/etc/sudoers.d/${USER_NAME}"

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
# `npm install` for the same reason as usd-viewer-build: no upstream lockfile.
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

# REGRESSION GUARD for the line above. Asserting the posture is the only thing
# that keeps it true: the `sys` sudoers grant was inherited all the way into the
# published GHCR image for its whole life, and nothing anywhere noticed. This
# runs as the runtime USER, so it asks exactly the question an attacker with a
# foothold in the shipped container would: can this user become root without a
# password? A `sudo` that is absent, or present and refuses, both pass.
RUN if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then \
        echo "runtime-test: the shipped image grants passwordless root to $(id -un)" >&2; \
        exit 1; \
    fi

# REGRESSION GUARD for what the `runtime` stage says it ships. ADR-0001 has an
# invariant ("no npm ... no dev toolchain") that the built image did not hold
# for its whole life, because nothing ever checked. `curl` is deliberately NOT
# in this list -- see the runtime stage header for why it stays.
RUN present=""; \
    for b in git npm npx corepack sudo; do \
        if command -v "${b}" >/dev/null 2>&1; then present="${present} ${b}"; fi; \
    done; \
    if [ -n "${present}" ]; then \
        echo "runtime-test: the shipped image still carries:${present}" >&2; \
        exit 1; \
    fi

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
COPY --chown="${USER}":"${GROUP}" package.json package-lock.json .npmrc /app/
COPY --chown="${USER}":"${GROUP}" packages/stream-core /app/packages/stream-core
COPY --chown="${USER}":"${GROUP}" examples/embedded-site-demo /app/examples/embedded-site-demo
# Same committed lockfile as stream-only-build; the workspace is partial here
# too (no apps/), which npm ci tolerates.
RUN npm ci && \
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
# CI helpers (#66): script/ci/ lands at /ci/ rather than /lint/ because it is
# also EXECUTED here -- derive_image_tag.bats runs the deriver in-image, which
# is the only proof of the tag -> image-tag mapping available without pushing
# a tag. Copied before the lint RUN so one copy serves both purposes.
COPY --chmod=0755 script/ci/ /ci/
# The WORKFLOW ITSELF, because the release invariant is now under test rather
# than merely argued for. The picture gate (#70) lives entirely in `if:` /
# `needs:` expressions in .github/workflows/main.yaml and nothing read them, so
# an edit that drops `tier-b-visual-e2e` from a `needs:` list left every gate
# green with the protection gone. release_gate_workflow.bats runs
# /ci/check_release_gates.sh over this file (and over mutated copies of it), so
# the file has to be in the image the bats run in. Same mechanism the specs
# already use for their inputs -- a COPY naming exactly what the stage owns.
COPY .github/workflows/main.yaml /workflows/main.yaml
# /lint/*.sh keeps our loose files (script/entrypoint.sh) covered on
# top of the template's wrapper + lib coverage; /ci/*.sh adds the CI
# helpers, which nothing else was linting.
RUN shellcheck -S warning /lint/*.sh /lint/wrapper/*.sh /lint/lib/*.sh /ci/*.sh
WORKDIR /lint
RUN hadolint Dockerfile

COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Tool-first smoke layout, base ADR-00000012: test/bats/smoke/<stage>/ names
# the STAGE each spec is built to run in, so the specs a stage owns are the
# ones its COPY names -- no spec can drift into an image that cannot satisfy
# it. All five of this repo's specs belong to `devel-test`: derive_image_tag
# and tier_b_visual_e2e need /ci/, release_gate_workflow needs /ci/ plus
# /workflows/, and example_demo needs /examples/, all of which exist only
# here, and omniverse_web_viewer_env needs /app/*/dist +
# /entrypoint.sh, which exist in
# `runtime` too -- but `runtime-test` runs RUNTIME_SMOKE_CMD, not bats, so
# there is no second consumer to justify a `shared/` tree today. The day a
# runtime-test bats block is added, moving that one file to shared/ is the
# whole change.
#
# Both trees flatten into /smoke_test/, so `load "${BATS_TEST_DIRNAME}/
# test_helper"` keeps resolving to the shared helper from .base.
COPY .base/test/smoke/ /smoke_test/
COPY test/bats/smoke/devel-test/ /smoke_test/

# Example source is checked by example_demo.bats (contract + node --test);
# the full example build (lint / vite / serve smoke) runs in the `example`
# stage above.
COPY examples/ /examples/

ARG USER
USER "${USER}"

RUN bats /smoke_test/

############################## e2e-test ##############################
# Tier-1 browser config-dial e2e (#47). FROM runtime so it drives the REAL
# served dists at /app/<mode>/dist through the production entrypoint -- the one
# layer the curl-200 runtime smoke never reaches (does the booted bundle feed
# the injected SIGNALING_SERVER:PORT, and the media port, into the stream
# client?). No GPU / Isaac / Kit: the app dials a dead test host and we record
# what it dials. Standalone, @nvidia-FREE (test/e2e is outside the npm
# workspaces, so installing it here never touches the private streaming-library
# registry). Built only as a build-worker `extra_stage` (per-PR), never pushed.
#
# This stage MUST NOT be named after the standard pipeline stages
# (sys/devel-base/devel/devel-test/runtime-test/runtime) -- base#415 extra_stages
# blocklist.
FROM runtime AS e2e-test

ARG USER_NAME="user"
ARG USER_GROUP="user"
ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"

# Browsers go to a world-readable path so the non-root USER can run them in the
# gate RUN below (Chromium refuses its sandbox as root). `node` comes from
# devel-base via runtime's FROM chain; `npm` does NOT -- `runtime` deletes it,
# so this stage COPYs it back from devel-base a few lines below.
ENV PLAYWRIGHT_BROWSERS_PATH="/opt/ms-playwright"

# Root for the apt install Playwright's `install --with-deps chromium` performs.
USER root

# `runtime` deletes npm/npx so the SHIPPED image does not carry a package
# manager. This stage is never pushed and needs one to install Playwright, so it
# takes npm back from `devel-base` rather than the shipped image keeping it for
# everyone's benefit. `node` itself comes from runtime's FROM chain, as before.
COPY --from=devel-base /usr/lib/node_modules/npm /usr/lib/node_modules/npm
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/bin/npm && \
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/bin/npx

WORKDIR /e2e
COPY --chown="${USER}":"${GROUP}" test/e2e/ /e2e/

# Install the e2e tooling (Playwright only -- no @nvidia) and the Chromium
# browser plus its OS deps. `--with-deps` apt-installs the headless libs.
# Browsers land in the world-readable PLAYWRIGHT_BROWSERS_PATH so the non-root
# user can launch them. hadolint ignore=DL3016
RUN npm ci --no-audit --no-fund && \
    npx playwright install --with-deps chromium && \
    chmod -R a+rx "${PLAYWRIGHT_BROWSERS_PATH}" && \
    chown -R "${USER}":"${GROUP}" /e2e

# Drop privilege: Chromium must not run as root. The gate renders+serves each
# mode via the entrypoint with distinctive test values, runs Playwright against
# the live server, and fails the build on any non-zero Playwright exit.
# Orchestration lives in run-in-image.sh (shellcheck-clean) so this RUN stays a
# single call rather than a giant inline script.
USER "${USER}"
RUN bash /e2e/run-in-image.sh
