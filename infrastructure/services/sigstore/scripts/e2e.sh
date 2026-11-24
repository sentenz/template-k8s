#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
: "${REGISTRY:?}"
export TUF_ANCHOR="$state/metadata/1.root.json"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$(mkcert -CAROOT)/rootCA.pem}"
run=$(mktemp -d "$state/test.XXXXXXXX")
build="$run/build"
mkdir "$build"
export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
if bundled_registry; then
  export DOCKER_CONFIG="$run/docker"
  mkdir "$DOCKER_CONFIG"
fi
trap 'rm -f "$run/token"; if bundled_registry; then rm -rf -- "$run/docker"; fi' EXIT
# Use a registry-scoped docker config with embedded auth, including on credential-helper hosts.
if bundled_registry; then
  jq -n --rawfile pw "$state/registry.password" '{auths:{"registry.local":{auth:(("publisher:"+$pw)|@base64)}}}' > "$DOCKER_CONFIG/config.json"
fi
if bundled_registry || [[ -n ${PULL_CONFIG:-} ]]; then
  k -n sigstore-test create secret generic registry-pull --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${PULL_CONFIG:-$DOCKER_CONFIG/config.json}" --dry-run=client -o yaml | apply
fi
arch=$(k get nodes -o json | jq -er '[.items[].status.nodeInfo.architecture]|unique|select(length==1)|first')
CGO_ENABLED=0 go build -o "$run/native" "$module/sample/main.go"
[[ $("$run/native") == sigstore-kind ]]
GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -o "$build/hello" "$module/sample/main.go"
cp "$module/sample/Dockerfile" "$build"
repo="${IMAGE_REPOSITORY:-$REGISTRY/sigstore/example}"
build_push() {
  local tag="$repo:$1-${run##*.}"
  docker build --platform "linux/$arch" --label "sigstore.local/test=$1-${run##*.}" -t "$tag" "$build" >&2
  docker push "$tag" >&2
  docker image inspect "$tag" | jq -er --arg prefix "$repo@sha256:" '.[0].RepoDigests[]|select(startswith($prefix))' | head -1
}
trusted=$(build_push approved)
unsigned=$(build_push unsigned)
other=$(build_push unapproved)
export SIGNER_ISSUER=$(k get --raw /.well-known/openid-configuration | jq -er .issuer)
export SIGNER_IDENTITY=https://kubernetes.io/namespaces/sigstore-ci/serviceaccounts/release
export TOKEN_FILE="$run/token"
k -n sigstore-ci create token release --audience sigstore --duration=10m | tr -d '\n' > "$TOKEN_FILE"
"$module/scripts/sign-release.sh" "$trusted" "$build/hello" "$run/evidence"
source "$module/scripts/client.sh"
sigstore_client "$TUF_ANCHOR"
k -n sigstore-ci create token unapproved --audience sigstore --duration=10m | tr -d '\n' > "$TOKEN_FILE"
cosign sign --yes --signing-config "$SIGSTORE_SIGNING_CONFIG" --trusted-root "$SIGSTORE_TRUSTED_ROOT" --identity-token "$TOKEN_FILE" "$other"
cosign verify --trusted-root "$SIGSTORE_TRUSTED_ROOT" --certificate-oidc-issuer "$SIGNER_ISSUER" \
  --certificate-identity "${SIGNER_IDENTITY%/*}/unapproved" "$other" >/dev/null
cp "$build/hello" "$run/changed"
echo modified >> "$run/changed"
if cosign verify-blob --trusted-root "$SIGSTORE_TRUSTED_ROOT" --certificate-identity "$SIGNER_IDENTITY" \
    --certificate-oidc-issuer "$SIGNER_ISSUER" --bundle "$run/evidence/artifact.sigstore.json" "$run/changed"; then fail "Modified artifact verified"; fi
for bundle in "$run"/evidence/*.sigstore.json; do
  entry=$(jq -er '.verificationMaterial.tlogEntries[0] | select(.inclusionProof.checkpoint.envelope != null) | .logIndex' "$bundle")
  curl -fsS "https://rekor.sigstore.local/api/v1/log/entries?logIndex=$entry" | jq -e --arg idx "$entry" 'any(.[]; (.logIndex|tostring)==$idx)' >/dev/null
done
suffix=$(basename "$run" | tr "[:upper:]." "[:lower:]-")
admit() {
  k -n sigstore-test run "check-${suffix}" --image="$1" --restart=Never --overrides='{"spec":{"imagePullSecrets":[{"name":"registry-pull"}]}}' "${@:2}"
}
for reference in "$unsigned" "$other"; do
  if admit "$reference" --dry-run=server > "$run/denial" 2>&1; then fail "Unapproved image admitted: $reference"; fi
  grep -Ei 'admission webhook.*denied' "$run/denial"
  grep -F sigstore-kind-signer "$run/denial"
done
admit "$trusted"
pod="check-${suffix}"
k -n sigstore-test wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$pod" --timeout=2m
[[ $(k -n sigstore-test logs "$pod") == sigstore-kind ]]
k -n sigstore-test delete pod "$pod"
rm -rf -- "$TUF_ROOT"
echo "Verification evidence: $run/evidence"
