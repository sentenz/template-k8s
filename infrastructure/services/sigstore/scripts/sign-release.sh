#!/usr/bin/env bash
# Runner entry point. Inputs are an already published digest and tested artifact.
set -euo pipefail
umask 077
source "$(dirname "$0")/client.sh"
: "${TUF_ANCHOR:?}" "${TOKEN_FILE:?projected OIDC token file}" "${SIGNER_IDENTITY:?}" "${SIGNER_ISSUER:?}"
image=${1:?image@sha256:digest} artifact=${2:?artifact} evidence=${3:?new evidence directory}
[[ $image =~ @sha256:[a-f0-9]{64}$ && -f $artifact && -s $TOKEN_FILE ]]
mkdir "$evidence"
sigstore_client "$TUF_ANCHOR"
trap 'rm -rf -- "$TUF_ROOT"' EXIT
sign=(--yes --identity-token "$TOKEN_FILE" --trusted-root "$SIGSTORE_TRUSTED_ROOT" --signing-config "$SIGSTORE_SIGNING_CONFIG")
verify=(--trusted-root "$SIGSTORE_TRUSTED_ROOT" --certificate-identity "$SIGNER_IDENTITY" --certificate-oidc-issuer "$SIGNER_ISSUER")
cosign sign "${sign[@]}" --bundle "$evidence/image.sigstore.json" "$image"
cosign verify "${verify[@]}" "$image" > "$evidence/image-verification.json"
cosign sign-blob "${sign[@]}" --bundle "$evidence/artifact.sigstore.json" "$artifact"
cosign verify-blob "${verify[@]}" --bundle "$evidence/artifact.sigstore.json" "$artifact"
printf '%s\n' "$image" > "$evidence/image.txt"
