# syntax=docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183
# SPDX-License-Identifier: Apache-2.0

FROM alpine/k8s:1.37.2@sha256:7a82aeefea3d554a43a8676b137f2b88bae6c1fe11c13862b191b3a086cc28c0 AS tools-k8s

FROM alpine/helm:4.3.2@sha256:a3b9d617c0c30a6c488cebb429c4ba83995a26dc2184599af5fd408a361b2e67 AS tools-helm

FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS tools-kind

# renovate: datasource=github-releases depName=kubernetes-sigs/kind
ARG KIND_VERSION=v0.33.0
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

FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS runtime

LABEL org.opencontainers.image.title="Kubernetes Toolchain" \
    org.opencontainers.image.description="Pinned Kubernetes command-line toolchain for local and CI workflows" \
    org.opencontainers.image.source="https://github.com/sentenz/template-k8s" \
    org.opencontainers.image.licenses="Apache-2.0" \
    org.opencontainers.image.vendor="sentenz" \
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
