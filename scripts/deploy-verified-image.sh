#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Deploy only an approved, immutable repository image; requires host Cosign and kubectl.
set -euo pipefail
[[ $# == 4 ]] || { echo "usage: $0 IMAGE@sha256:DIGEST NAMESPACE DEPLOYMENT CONTAINER" >&2; exit 2; }
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="$1"
python3 "$repository_root/.github/actions/sigstore/sigstore.py" \
  --policy "$repository_root/.github/sigstore/policy.json" \
  --operation verify --kind image --image "$image" \
  --identity https://github.com/sentenz/template-k8s/.github/workflows/docker.yml@refs/heads/main
kubectl --namespace "$2" set image "deployment/$3" "$4=$image"
kubectl --namespace "$2" rollout status "deployment/$3" --timeout=5m
