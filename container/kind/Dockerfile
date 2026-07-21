# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: Apache-2.0

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

ARG KIND_VERSION=v0.32.0
ARG TARGETARCH
ARG TARGETOS=linux

LABEL org.opencontainers.image.title="kind CLI" \
      org.opencontainers.image.description="Containerized client environment for the Kubernetes kind CLI" \
      org.opencontainers.image.source="https://github.com/sentenz/template-k8s" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN set -eux; \
    apk add --no-cache \
      ca-certificates \
      curl \
      docker-cli; \
    if [ "${TARGETOS}" != "linux" ]; then \
      echo "Unsupported target operating system: ${TARGETOS}" >&2; \
      exit 1; \
    fi; \
    arch="${TARGETARCH}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64) arch="arm64" ;; \
        *) echo "Unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64|arm64) ;; \
      *) echo "Unsupported target architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    binary="kind-linux-${arch}"; \
    release_url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"; \
    curl -fsSLo "/tmp/${binary}" "${release_url}/${binary}"; \
    curl -fsSLo "/tmp/${binary}.sha256sum" "${release_url}/${binary}.sha256sum"; \
    cd /tmp; \
    sha256sum -c "${binary}.sha256sum"; \
    mv "${binary}" /usr/local/bin/kind; \
    chmod 0755 /usr/local/bin/kind; \
    rm -f "${binary}.sha256sum"

WORKDIR /workspace

ENTRYPOINT ["kind"]
CMD ["version"]
