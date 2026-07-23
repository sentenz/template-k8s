# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: Apache-2.0

ARG ALPINE_IMAGE=alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ARG GO_IMAGE=golang:1.24.13-alpine3.23

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS kustomize

ARG TARGETARCH
ARG TARGETOS=linux
ARG KUSTOMIZE_VERSION=v5.8.1

ENV CGO_ENABLED=0 \
    GOFLAGS=-trimpath \
    GOPROXY=https://proxy.golang.org,direct \
    GOSUMDB=sum.golang.org \
    GOTOOLCHAIN=local

RUN --mount=type=cache,id=go-build,target=/root/.cache/go-build,sharing=locked \
    --mount=type=cache,id=go-mod,target=/go/pkg/mod,sharing=locked \
    test "${TARGETOS}" = linux; \
    case "${TARGETARCH}" in amd64|arm64) ;; *) exit 1 ;; esac; \
    GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" GOBIN=/out \
      go install -ldflags='-s -w' "sigs.k8s.io/kustomize/kustomize/v5@${KUSTOMIZE_VERSION}"; \
    go version -m /out/kustomize | grep -F "sigs.k8s.io/kustomize/kustomize/v5\t${KUSTOMIZE_VERSION}"

FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE} AS tools

ARG TARGETARCH
ARG TARGETOS=linux
ARG K8S_TOOLS="kubectl kind helm"
ARG CHECKSUM_POLICY=remote

ARG KUBECTL_VERSION=v1.36.1
ARG KIND_VERSION=v0.32.0
ARG HELM_VERSION=v4.1.4

ARG KUBECTL_SHA256=""
ARG KIND_SHA256=""
ARG HELM_SHA256=""

ARG KUBECTL_SHA256_AMD64=""
ARG KUBECTL_SHA256_ARM64=""
ARG KIND_SHA256_AMD64=""
ARG KIND_SHA256_ARM64=""
ARG HELM_SHA256_AMD64=""
ARG HELM_SHA256_ARM64=""

RUN apk add --no-cache \
      bash \
      ca-certificates \
      coreutils \
      curl \
      tar

COPY --chmod=0755 scripts/install-k8s-tools.sh /usr/local/sbin/install-k8s-tools

RUN --mount=type=cache,id=k8s-tool-downloads,target=/var/cache/k8s-tools,sharing=locked \
    INSTALL_DIR=/opt/k8s-tools \
    DOWNLOAD_CACHE_DIR=/var/cache/k8s-tools \
    TARGETOS="${TARGETOS}" \
    TARGETARCH="${TARGETARCH}" \
    TOOLS="${K8S_TOOLS}" \
    CHECKSUM_POLICY="${CHECKSUM_POLICY}" \
    KUBECTL_VERSION="${KUBECTL_VERSION}" \
    KIND_VERSION="${KIND_VERSION}" \
    HELM_VERSION="${HELM_VERSION}" \
    KUBECTL_SHA256="${KUBECTL_SHA256}" \
    KIND_SHA256="${KIND_SHA256}" \
    HELM_SHA256="${HELM_SHA256}" \
    KUBECTL_SHA256_AMD64="${KUBECTL_SHA256_AMD64}" \
    KUBECTL_SHA256_ARM64="${KUBECTL_SHA256_ARM64}" \
    KIND_SHA256_AMD64="${KIND_SHA256_AMD64}" \
    KIND_SHA256_ARM64="${KIND_SHA256_ARM64}" \
    HELM_SHA256_AMD64="${HELM_SHA256_AMD64}" \
    HELM_SHA256_ARM64="${HELM_SHA256_ARM64}" \
    VERIFY_EXECUTABLE=auto \
    /usr/local/sbin/install-k8s-tools

COPY --from=kustomize /out/kustomize /opt/k8s-tools/kustomize

FROM ${ALPINE_IMAGE}

ARG KUBECTL_VERSION=v1.36.1
ARG KUSTOMIZE_VERSION=v5.8.1
ARG KIND_VERSION=v0.32.0
ARG HELM_VERSION=v4.1.4

LABEL org.opencontainers.image.title="Kubernetes CLI toolchain" \
      org.opencontainers.image.description="Checksum-verified kubectl, Kustomize, kind, and Helm client environment" \
      org.opencontainers.image.source="https://github.com/sentenz/template-k8s" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.sentenz.k8s.kubectl.version="${KUBECTL_VERSION}" \
      io.sentenz.k8s.kustomize.version="${KUSTOMIZE_VERSION}" \
      io.sentenz.k8s.kind.version="${KIND_VERSION}" \
      io.sentenz.k8s.helm.version="${HELM_VERSION}"

RUN apk add --no-cache \
      ca-certificates \
      docker-cli

COPY --from=tools /opt/k8s-tools/ /usr/local/bin/
COPY --chmod=0755 container/kind/k8s-entrypoint.sh /usr/local/bin/k8s-entrypoint

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/k8s-entrypoint"]
