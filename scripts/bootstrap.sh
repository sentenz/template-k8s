#!/usr/bin/env bash

set -euo pipefail

readonly KIND_VERSION="${KIND_VERSION:-v0.32.0}"

if ! command -v kubectl &>/dev/null; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl
  mv kubectl /usr/local/bin/
fi

if ! command -v kustomize &>/dev/null; then
  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
  mv kustomize /usr/local/bin/
fi

if ! command -v helm &>/dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v kind &>/dev/null; then
  case "$(uname -m)" in
    x86_64) kind_arch="amd64" ;;
    aarch64|arm64) kind_arch="arm64" ;;
    *)
      echo "Unsupported architecture for Kind: $(uname -m)" >&2
      exit 1
      ;;
  esac

  kind_binary="kind-linux-${kind_arch}"
  kind_tmpdir="$(mktemp -d)"
  trap 'rm -rf "${kind_tmpdir}"' EXIT

  curl -fsSLo "${kind_tmpdir}/${kind_binary}" \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/${kind_binary}"
  install -m 0755 "${kind_tmpdir}/${kind_binary}" /usr/local/bin/kind
fi
