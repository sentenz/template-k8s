#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
interactive=${1:-https://dex.sigstore.local}
mkdir -p "$state/source"
# Serialize refreshes from this checkout and reject accidental trust changes.
exec 9>"$state/publish.lock"
flock -n 9 || fail "Another TUF refresh is active"
ca="$(mkcert -CAROOT)/rootCA.pem"
k -n fulcio-system get secret fulcio-server-secret -o jsonpath='{.data.cert}' | base64 -d > "$state/fulcio.pem"
k -n ctlog-system get secret ctlog-public-key -o jsonpath='{.data.public}' | base64 -d > "$state/ctfe.pub"
curl --fail --silent --show-error --cacert "$ca" https://rekor.sigstore.local/api/v1/log/publicKey > "$state/rekor.pub"
curl --fail --silent --show-error --cacert "$ca" https://fulcio.sigstore.local/healthz >/dev/null
if [[ ! -e $state/start-time ]]; then date -u +%Y-%m-%dT%H:%M:%SZ > "$state/start-time"; fi
start=$(cat "$state/start-time")
cosign trusted-root create --fulcio="url=https://fulcio.sigstore.local,certificate-chain=$state/fulcio.pem" \
  --rekor="url=https://rekor.sigstore.local,public-key=$state/rekor.pub,start-time=$start" \
  --ctfe="url=http://ctlog.ctlog-system.svc/sigstorescaffolding,public-key=$state/ctfe.pub,start-time=$start" \
  --out "$state/source/trusted_root.json"
if [[ -f $state/targets/trusted_root.json ]]; then
  diff -q <(jq -S . "$state/targets/trusted_root.json") <(jq -S . "$state/source/trusted_root.json") || fail "Service keys changed. Perform a trust rotation before publication."
fi
cosign signing-config create --fulcio="url=https://fulcio.sigstore.local,api-version=1,start-time=$start,operator=kind" \
  --rekor="url=https://rekor.sigstore.local,api-version=1,start-time=$start,operator=kind" --rekor-config ANY \
  --oidc-provider="url=$interactive,api-version=1,start-time=$start,operator=kind" --out "$state/source/signing_config.v0.2.json"
python3 "$module/tools/repository.py" "$state" "$state/source"
for part in targets metadata; do
  k -n tuf-system create cm "tuf-$part" --from-file="$state/$part" --dry-run=client -o yaml | apply
done
k apply -f "$values/workloads.yaml"
k -n tuf-system rollout status deploy/tuf --timeout=3m
# ConfigMap projection propagation can lag a ready Deployment on refresh.
for attempt in {1..60}; do
  if curl -fsS --cacert "$ca" https://tuf.sigstore.local/timestamp.json | cmp -s - "$state/metadata/timestamp.json"; then exit 0; fi
  sleep 2
done
fail "The TUF endpoint has not published the new timestamp"
