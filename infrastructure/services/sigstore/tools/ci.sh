#!/usr/bin/env bash
# Release stage on a trusted runner with a projected sigstore-audience token.
set -euo pipefail
umask 077
module=$(cd "$(dirname "$0")/.." && pwd)
: "${IMAGE_REPOSITORY:?}" "${RELEASE_TAG:?immutable, unique build tag}" "${TOKEN_FILE:?}" "${TUF_ANCHOR:?}"
: "${SIGNER_ISSUER:?}" "${SIGNER_IDENTITY:?}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
mkdir context
CGO_ENABLED=0 go build -o test-binary "$module/sample/main.go"
[[ $(./test-binary) == sigstore-kind ]]
GOOS=linux GOARCH="${TARGETARCH:-amd64}" CGO_ENABLED=0 go build -trimpath -o context/hello "$module/sample/main.go"
cp "$module/sample/Dockerfile" context/
tag="$IMAGE_REPOSITORY:$RELEASE_TAG"
docker build --platform "linux/${TARGETARCH:-amd64}" -t "$tag" context/
docker push "$tag"
digest=$(oras resolve "$tag")
image="$IMAGE_REPOSITORY@$digest"
cp context/hello hello
oras push "$IMAGE_REPOSITORY:artifact-$RELEASE_TAG" --artifact-type application/octet-stream hello:application/octet-stream
"$module/tools/sign-release.sh" "$image" hello evidence
oras attach "$image" --artifact-type application/vnd.sigstore.verification.evidence.v1 \
  evidence/image.sigstore.json:application/json evidence/artifact.sigstore.json:application/json \
  evidence/image-verification.json:application/json evidence/image.txt:text/plain
# Kubernetes evaluates the image policy for this Job and its Pod.
jq -n --arg image "$image" '{apiVersion:"batch/v1",kind:"Job",metadata:{generateName:"verified-release-",namespace:"sigstore-test"},
  spec:{backoffLimit:0,ttlSecondsAfterFinished:600,template:{spec:{automountServiceAccountToken:false,
  imagePullSecrets:[{name:"registry-pull"}],restartPolicy:"Never",containers:[{name:"release",image:$image}]}}}}' > job.json
kubectl create --dry-run=server -f job.json >/dev/null
job=$(kubectl create -f job.json -o name)
kubectl -n sigstore-test wait --for=condition=Complete "$job" --timeout=3m
