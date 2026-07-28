# syntax=docker/dockerfile:1.25
# SPDX-License-Identifier: Apache-2.0

ARG KUBECTL_VERSION=1.36.2
ARG K8S_TOOLS_SHA256=44ef4942e171939b9c665a4a84beb80e2dcdb9a24330d4651cfdfd2e9deecc47
ARG KUSTOMIZE_VERSION=v5.8.1
ARG KIND_VERSION=v0.32.0
ARG HELM_VERSION=4.2.3
ARG HELM_SHA256=b97ba4f9b27fe7af16ee3d37e6815783c9d4a51289b6240a9024ec471611ae9b

FROM alpine/k8s:${KUBECTL_VERSION}@sha256:${K8S_TOOLS_SHA256} AS k8s-tools

FROM alpine/helm:${HELM_VERSION}@sha256:${HELM_SHA256} AS helm

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS kind-installer

ARG KIND_VERSION
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

ARG KUBECTL_VERSION
ARG KUSTOMIZE_VERSION
ARG KIND_VERSION
ARG HELM_VERSION

LABEL org.opencontainers.image.title="Kubernetes toolchain" \
      org.opencontainers.image.description="Pinned Kubernetes command-line toolchain for local workflows" \
      org.opencontainers.image.source="https://github.com/sentenz/template-k8s" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.k8s.tools.selection="kubectl,kustomize,kind,helm" \
      io.k8s.tools.kubectl.version="v${KUBECTL_VERSION}" \
      io.k8s.tools.kustomize.version="${KUSTOMIZE_VERSION}" \
      io.k8s.tools.kind.version="${KIND_VERSION}" \
      io.k8s.tools.helm.version="v${HELM_VERSION}"

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

COPY --from=k8s-tools /usr/bin/kubectl /usr/local/bin/kubectl
COPY --from=k8s-tools /usr/bin/kustomize /usr/local/bin/kustomize
COPY --from=kind-installer /opt/k8s/bin/kind /usr/local/bin/kind
COPY --from=helm /usr/bin/helm /usr/local/bin/helm

WORKDIR /workspace

USER k8s

CMD ["/bin/bash"]
