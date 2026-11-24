#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
source "$module/tools/client.sh"
action=$1
image=$2
[[ $image =~ @sha256:[a-f0-9]{64}$ ]] || fail "Specify an immutable IMAGE=repository@sha256:digest"
export SSL_CERT_FILE=${SSL_CERT_FILE:-$(mkcert -CAROOT)/rootCA.pem}
sigstore_client "${TUF_ANCHOR:-$state/metadata/1.root.json}"
trap 'rm -rf -- "$TUF_ROOT"; if [[ -n ${temporary_token:-} ]]; then rm -f -- "$temporary_token"; fi' EXIT
if [[ $action == sign ]]; then
  if [[ -z ${TOKEN_FILE:-} ]]; then
    temporary_token=$(mktemp)
    k -n sigstore-ci create token release --audience=sigstore --duration=10m | tr -d '\n' > "$temporary_token"
    TOKEN_FILE=$temporary_token
  fi
  cosign sign --yes --identity-token "$TOKEN_FILE" --signing-config "$SIGSTORE_SIGNING_CONFIG" \
    --trusted-root "$SIGSTORE_TRUSTED_ROOT" "$image"
else
  issuer=${SIGNER_ISSUER:-}
  if [[ -z $issuer ]]; then issuer=$(k get --raw /.well-known/openid-configuration | jq -er .issuer); fi
  cosign verify --trusted-root "$SIGSTORE_TRUSTED_ROOT" --certificate-oidc-issuer "$issuer" \
    --certificate-identity "${SIGNER_IDENTITY:-https://kubernetes.io/namespaces/sigstore-ci/serviceaccounts/release}" "$image"
fi
