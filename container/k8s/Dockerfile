# syntax=docker/dockerfile:1.26@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# SPDX-License-Identifier: Apache-2.0


FROM alpine/k8s:1.36.2@sha256:44ef4942e171939b9c665a4a84beb80e2dcdb9a24330d4651cfdfd2e9deecc47 AS tools-k8s

FROM alpine/helm:4.2.4@sha256:76c375eed56144c68d6197c55bc5a4552fb42002190b796729901cbab3ae6e51 AS tools-helm

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS tools-kind

ARG KIND_VERSION=v0.32.0
ARG TARGETOS=linux
ARG TARGETARCH

RUN apk upgrade --no-cache \
    && apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    curl

COPY --chmod=0755 scripts/bootstrap.sh /usr/local/bin/bootstrap.sh

RUN INSTALL_DIR=/opt/k8s/bin \
    KIND_VERSION="${KIND_VERSION}" \
    TARGETOS="${TARGETOS}" \
    TARGETARCH="${TARGETARCH}" \
    /usr/local/bin/bootstrap.sh --tool kind

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS runtime

LABEL org.opencontainers.image.title="Kubernetes toolchain" \
    org.opencontainers.image.description="Pinned Kubernetes command-line toolchain for local workflows" \
    org.opencontainers.image.source="https://github.com/sentenz/template-k8s" \
    org.opencontainers.image.licenses="Apache-2.0" \
    io.k8s.tools.selection="kubectl,kustomize,kind,helm"

RUN apk upgrade --no-cache \
    && apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    docker-cli \
    git \
    openssh-client

ARG USER_GID=10001
ARG USER_UID=10001

ENV HOME=/home/k8s

RUN addgroup -S -g "${USER_GID}" k8s \
    && adduser -S -D -h "${HOME}" -G k8s -u "${USER_UID}" k8s \
    && mkdir -p "${HOME}" /workspace \
    && chown -R "${USER_UID}:${USER_GID}" "${HOME}" /workspace \
    && chmod 0750 "${HOME}" \
    && chmod 0755 /workspace

COPY --from=tools-k8s --link --chown=0:0 --chmod=0755 /usr/bin/kubectl /usr/bin/kustomize /usr/local/bin/
COPY --from=tools-kind --link --chown=0:0 --chmod=0755 /opt/k8s/bin/kind /usr/local/bin/kind
COPY --from=tools-helm --link --chown=0:0 --chmod=0755 /usr/bin/helm /usr/local/bin/helm

WORKDIR /workspace

USER ${USER_UID}:${USER_GID}

CMD ["/bin/bash"]
