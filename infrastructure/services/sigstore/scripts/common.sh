#!/usr/bin/env bash
set -euo pipefail
umask 077
module=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(git -C "$module" rev-parse --show-toplevel)
cluster=${KIND_CLUSTER_NAME:-template-k8s}
export KUBECONFIG=${KUBECONFIG:-$root/.local/kubeconfig/dev.yaml}
state="$root/.local/sigstore/$cluster"
values="$module/overlays/dev"
context="kind-$cluster"
bundled_registry() {
  [[ ${REGISTRY:-} == registry.local && ${USE_EXISTING_REGISTRY:-0} != 1 ]]
}
k() { kubectl --context "$context" "$@"; }
h() { helm --kube-context "$context" "$@"; }
fail() { echo "$*" >&2; exit 1; }
apply() { k apply --server-side --field-manager=sigstore-kind -f -; }
chart() {
  local name=$1 version=$2 checksum=$3 file="$state/$1-$2.tgz"
  if [[ ! -f $file ]]; then
    helm pull "$name" --version "$version" --repo https://sigstore.github.io/helm-charts --destination "$state" || return 1
  fi
  echo "$checksum  $file" | sha256sum --check >&2 || return 1
  echo "$file"
}
