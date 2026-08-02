# syntax=docker/dockerfile:1.26
# SPDX-License-Identifier: Apache-2.0


FROM alpine/k8s:1.36.2@sha256:44ef4942e171939b9c665a4a84beb80e2dcdb9a24330d4651cfdfd2e9deecc47 AS tools-k8s

FROM alpine/helm:4.2.3@sha256:b97ba4f9b27fe7af16ee3d37e6815783c9d4a51289b6240a9024ec471611ae9b AS tools-helm

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

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b


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
    openssh-client \
    && addgroup -S k8s \
    && adduser -S -D -h /home/k8s -G k8s k8s \
    && mkdir -p /workspace \
    && chown k8s:k8s /workspace

COPY --from=tools-k8s /usr/bin/kubectl /usr/local/bin/kubectl
COPY --from=tools-k8s /usr/bin/kustomize /usr/local/bin/kustomize
COPY --from=tools-kind /opt/k8s/bin/kind /usr/local/bin/kind
COPY --from=tools-helm /usr/bin/helm /usr/local/bin/helm

WORKDIR /workspace

USER k8s

CMD ["/bin/bash"]
