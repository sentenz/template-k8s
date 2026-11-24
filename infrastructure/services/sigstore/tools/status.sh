#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
export CURL_CA_BUNDLE="$(mkcert -CAROOT)/rootCA.pem"
k get --raw /readyz
k get deploy,job,pvc -A -l app.kubernetes.io/instance=kind-sigstore
k get trustroot/sigstore-kind clusterimagepolicy/sigstore-kind-signer
curl -fsS https://fulcio.sigstore.local/healthz
curl -fsS https://rekor.sigstore.local/api/v1/log | jq '{treeID,treeSize,rootHash,signedTreeHead}'
k get --raw '/api/v1/namespaces/ctlog-system/services/http:ctlog:6962-tcp/proxy/sigstorescaffolding/ct/v1/get-sth' |
  jq -e '{tree_size,timestamp,sha256_root_hash,tree_head_signature} | select(.tree_head_signature != null)'
curl -fsS https://tuf.sigstore.local/timestamp.json | jq -er '.signed.expires'
