# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: Apache-2.0

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS installer

ARG KUBECTL_VERSION=v1.36.1
ARG KUSTOMIZE_VERSION=v5.8.1
ARG KIND_VERSION=v0.32.0
ARG HELM_VERSION=v4.2.0
ARG TARGETOS=linux
ARG TARGETARCH

RUN apk add --no-cache \
      bash \
      ca-certificates \
      coreutils \
      curl \
      tar

COPY --chmod=0755 scripts/install-tools.sh /usr/local/bin/install-tools.sh

RUN INSTALL_DIR=/opt/k8s/bin \
    KUBECTL_VERSION="${KUBECTL_VERSION}" \
    KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION}" \
    KIND_VERSION="${KIND_VERSION}" \
    HELM_VERSION="${HELM_VERSION}" \
    TARGETOS="${TARGETOS}" \
    TARGETARCH="${TARGETARCH}" \
    /usr/local/bin/install-tools.sh

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

ARG KUBECTL_VERSION=v1.36.1
ARG KUSTOMIZE_VERSION=v5.8.1
ARG KIND_VERSION=v0.32.0
ARG HELM_VERSION=v4.2.0

LABEL org.opencontainers.image.title="Kubernetes toolchain" \
      org.opencontainers.image.description="Verified kubectl, Kustomize, kind, and Helm toolchain for local Kubernetes workflows" \
      org.opencontainers.image.source="https://github.com/sentenz/template-k8s" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.sentenz.k8s.kubectl.version="${KUBECTL_VERSION}" \
      io.sentenz.k8s.kustomize.version="${KUSTOMIZE_VERSION}" \
      io.sentenz.k8s.kind.version="${KIND_VERSION}" \
      io.sentenz.k8s.helm.version="${HELM_VERSION}"

RUN apk add --no-cache \
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

COPY --from=installer /opt/k8s/bin/ /usr/local/bin/
COPY --chmod=0755 container/k8s/entrypoint.sh /usr/local/bin/k8s-entrypoint

WORKDIR /workspace

# Root is retained intentionally because access to a host Docker socket is already
# root-equivalent and its group ownership is determined at runtime. Run with
# --user where the mounted runtime socket and workspace permissions permit it.
ENTRYPOINT ["/usr/local/bin/k8s-entrypoint"]
CMD []
