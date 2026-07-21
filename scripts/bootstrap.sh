#!/usr/bin/env bash

set -euo pipefail

readonly KIND_VERSION="${KIND_VERSION:-v0.32.0}"

install_to_path() {
  local src="$1"
  local dest="$2"
  local install_dir=""

  if [[ -w /usr/local/bin ]]; then
    install_dir="/usr/local/bin"
  elif [[ -n "${HOME:-}" ]]; then
    install_dir="${HOME}/.local/bin"
    mkdir -p "${install_dir}"
    export PATH="${install_dir}:${PATH}"
    if ! grep -qF "${install_dir}" "${HOME}/.bashrc" 2>/dev/null; then
      printf '\n# Added by template-k8s bootstrap\nexport PATH="%s:$PATH"\n' "${install_dir}" >> "${HOME}/.bashrc"
    fi
  else
    echo "Unable to determine a writable install directory for ${dest}" >&2
    exit 1
  fi

  install -m 0755 "${src}" "${install_dir}/${dest}"
}

if ! command -v kubectl &>/dev/null; then
  kubectl_tmpdir="$(mktemp -d)"
  trap 'rm -rf "${kubectl_tmpdir}"' EXIT

  curl -fsSLo "${kubectl_tmpdir}/kubectl" \
    "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install_to_path "${kubectl_tmpdir}/kubectl" kubectl
fi

if ! command -v kustomize &>/dev/null; then
  kustomize_tmpdir="$(mktemp -d)"
  trap 'rm -rf "${kustomize_tmpdir}"' EXIT

  (
    cd "${kustomize_tmpdir}"
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
  )
  install_to_path "${kustomize_tmpdir}/kustomize" kustomize
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
  install_to_path "${kind_tmpdir}/${kind_binary}" kind
fi
