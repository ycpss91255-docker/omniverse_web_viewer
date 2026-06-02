ARG BASE_IMAGE="ubuntu:24.04"
ARG TEST_TOOLS_IMAGE="test-tools:local"

############################## sys ##############################
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
        useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"; \
    fi && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

############################## devel-base ##############################
FROM sys AS devel-base

ARG DEBIAN_FRONTEND=noninteractive

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

############################## devel ##############################
FROM devel-base AS devel

ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
ARG SETUP_DIR="/tmp/setup"
ARG CONFIG_SRC="config"

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chmod=0755 .base/script/docker/_entrypoint_logging.sh /usr/local/lib/base/_entrypoint_logging.sh
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"
COPY --chmod=0755 .base/dockerfile/setup "${SETUP_DIR}"

USER "${USER}"

ENV HOME="/home/${USER_NAME}"

RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    sudo rm -rf "${CONFIG_DIR}" "${SETUP_DIR}"

COPY --chown="${USER}":"${GROUP}" src/package.json src/.npmrc /app/
WORKDIR /app
RUN npm install

COPY --chown="${USER}":"${GROUP}" src/ /app/
# Overlay org-owned files on top of the upstream sample (src is a pinned
# read-only submodule). stream.config.json adds a `ui` block; App.tsx reads
# it to pick the initial form. Re-sync these on an upstream version bump.
COPY --chown="${USER}":"${GROUP}" overlay/stream.config.json /app/stream.config.json
COPY --chown="${USER}":"${GROUP}" overlay/App.tsx /app/src/App.tsx
RUN sed -i 's|"server":.*|"server": "__OWV_SERVER__",|' stream.config.json && \
    sed -i 's|"signalingPort":.*|"signalingPort": "__OWV_PORT__",|' stream.config.json && \
    sed -i 's|"mode":.*|"mode": "__OWV_UI_MODE__",|' stream.config.json && \
    sed -i 's|"autoLaunch":.*|"autoLaunch": "__OWV_AUTOLAUNCH__"|' stream.config.json && \
    npm run build && \
    for f in dist/assets/*.js; do \
        if grep -q '__OWV_' "${f}"; then cp -- "${f}" "${f}.tmpl"; fi; \
    done

WORKDIR "${HOME}/work"

ENV SIGNALING_SERVER="127.0.0.1"
ENV SIGNALING_PORT="49100"
ENV SERVE_PORT="5173"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sh", "-c", "serve -s /app/dist -l ${SERVE_PORT}"]

############################## serve ##############################
# Profile-gated extra stage for detached server use. Base template
# auto-emits this as a compose service with stdin_open: false /
# tty: false, avoiding the /dev/pts permission issue that the
# devel service's tty: true triggers under privileged: false.
# Usage: make run -- -t serve -d. Closes #9.
FROM devel AS serve

############################## devel-test ##############################
FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage

FROM devel AS devel-test

USER root

COPY --from=test-tools-stage /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=test-tools-stage /usr/local/bin/hadolint /usr/local/bin/hadolint

COPY .hadolint.yaml /lint/.hadolint.yaml
COPY Dockerfile /lint/Dockerfile
COPY script/*.sh /lint/
COPY .base/script/docker/_lib.sh \
     .base/script/docker/i18n.sh \
     .base/script/docker/_tui_conf.sh \
     /lint/
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
RUN cd /lint && hadolint Dockerfile

COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/

ARG USER
USER "${USER}"

RUN bats /smoke_test/
