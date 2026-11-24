#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
"$module/tools/inspect.sh"
: "${REGISTRY:?Set REGISTRY to an existing TLS registry authority, or registry.local for the bundled registry}"
[[ $REGISTRY != */* ]] || fail "REGISTRY must be a hostname with optional port"
python3 -c 'import bcrypt,tuf,securesystemslib'
mkdir -p "$state"
exec 8>"$state/install.lock"
flock -n 8 || fail "Another Sigstore installation is active"
issuer=$(k get --raw /.well-known/openid-configuration | jq -er .issuer)
[[ $issuer == https://kubernetes.default.svc || $issuer == https://kubernetes.default.svc.cluster.local ]] || fail "Review the cluster issuer before configuring Fulcio: $issuer"
interactive=${OIDC_ISSUER:-https://dex.sigstore.local}
[[ $interactive == https://* && $interactive != "$issuer" ]] || fail "Expected a distinct HTTPS interactive issuer"
scaffold=$(chart scaffold 0.6.125 2f6b5f4da8d699ad57d4ef9604f88026b65f2a239ed0dbd415fa5f48c19da1e6)
controller=$(chart policy-controller 0.10.8 71ecc9f1168dd7ad04b2f7456c2d492b5ca3e09a31883bb71f6369213ceeb814)
core_names=()
mapfile -t core_names < <(sed -n 's/^  name: //p' "$module/base/namespaces.yaml")
optional_names=()
hosts=(fulcio.sigstore.local rekor.sigstore.local tuf.sigstore.local)
if [[ $interactive == https://dex.sigstore.local ]]; then optional_names+=(sigstore-oidc); hosts+=(dex.sigstore.local); fi
if bundled_registry; then optional_names+=(sigstore-registry); hosts+=(registry.local); fi
names=("${core_names[@]}" "${optional_names[@]}")
# Reserve dedicated namespaces only. Pre-existing unrelated installs require integration review.
for ns in "${names[@]}"; do
  current=$(k get ns "$ns" --ignore-not-found -o json)
  [[ -z $current ]] || jq -e '.metadata.labels["sigstore.local/owner"]=="template-k8s"' <<<"$current" >/dev/null || fail "Namespace already in use: $ns"
done
# Do not claim an existing hostname served by an unrelated ingress.
ingresses=$(k get ingress -A -o json)
for host in "${hosts[@]}"; do
  owners=$(jq -r --arg host "$host" '.items[] | select(any(.spec.rules[]?; .host==$host)) | .metadata.namespace' <<<"$ingresses")
  for ns in $owners; do
    [[ $(k get ns "$ns" -o json | jq -r '.metadata.labels["sigstore.local/owner"]') == template-k8s ]] || fail "Existing ingress owns $host in $ns"
  done
done
if ! h status kind-policy -n sigstore-policy >/dev/null 2>&1; then
  [[ -z $(k get crd clusterimagepolicies.policy.sigstore.dev --ignore-not-found -o name) ]] || fail "An existing policy-controller requires integration review"
fi
ca="$(mkcert -CAROOT)/rootCA.pem"
[[ -r $ca ]] || fail "Initialize the local endpoint CA with mkcert -install"
uid=$(k get ns kube-system -o jsonpath='{.metadata.uid}')
if [[ -e $state/cluster-id && $(cat "$state/cluster-id") != "$uid" ]]; then fail "State belongs to a different cluster"; fi
if k get namespace tuf-system >/dev/null 2>&1; then
  existing=$(k -n tuf-system get cm tuf-metadata --ignore-not-found -o json)
  if [[ -n $existing ]]; then
    [[ -f $state/metadata/1.root.json ]] || fail "Restore the original TUF publisher state"
    jq -erj '.data["1.root.json"]' <<<"$existing" | cmp - "$state/metadata/1.root.json" || fail "TUF anchor mismatch"
  fi
fi
mysql_host=${TRILLIAN_MYSQL_HOST:-}
mysql_port=${TRILLIAN_MYSQL_PORT:-3306}
database_profile=bundled
database_values=()
if [[ -n $mysql_host ]]; then
  [[ $mysql_host =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail "TRILLIAN_MYSQL_HOST must be a DNS hostname"
  [[ $mysql_port =~ ^[0-9]{1,5}$ ]] && (( 10#$mysql_port > 0 && 10#$mysql_port <= 65535 )) || fail "Invalid TRILLIAN_MYSQL_PORT"
  jq -en --arg host "$mysql_host" --argjson port "$((10#$mysql_port))" '{trillian:{mysql:{hostname:$host,port:$port}}}' > "$state/mysql-endpoint.json"
  database_values=(-f "$values/external-mysql.yaml" -f "$state/mysql-endpoint.json")
  database_profile="$mysql_host:$mysql_port"
  # Never reuse a database from another installation without an explicit migration.
  k -n trillian-system get secret sigstore-mysql -o json |
    jq -e '.data | all(."mysql-user", ."mysql-password", ."mysql-database"; type=="string" and length>0)' >/dev/null ||
    fail "Provision the MySQL Secret in trillian-system before installing"
fi
if [[ -f $state/database-profile ]]; then
  [[ $(cat "$state/database-profile") == "$database_profile" ]] || fail "Changing the Trillian database requires migrating both log trees"
elif h status kind-sigstore -n sigstore-system >/dev/null 2>&1; then
  [[ $database_profile == bundled ]] || fail "Changing the Trillian database requires migrating both log trees"
fi
# Record the storage choice before Helm can initialize either tree.
printf '%s\n' "$database_profile" > "$state/database-profile"
echo "$uid" > "$state/cluster-id"
k kustomize "$module/base" | apply
for ns in "${optional_names[@]}"; do
  k create namespace "$ns" --dry-run=client -o json |
    jq '.metadata.labels["sigstore.local/owner"]="template-k8s"' | apply
done
for ns in "${names[@]}"; do
  cat <<YAML | apply
apiVersion: v1
kind: LimitRange
metadata: {name: local-defaults, namespace: $ns}
spec:
  limits:
    - type: Container
      defaultRequest: {cpu: 25m, memory: 32Mi}
      default: {cpu: "1", memory: 512Mi}
YAML
done
ip=$(k -n traefik get svc traefik -o jsonpath='{.spec.clusterIP}')
if [[ ${MANAGE_CLUSTER_DNS:-1} == 1 ]]; then python3 "$module/tools/dns.py" "$context" install "$ip" "${hosts[@]}"; fi
python3 "$module/tools/credentials.py" "$state"
route() {
  local ns=$1 host=$2 service=$3
  if ! openssl verify -CAfile "$ca" -verify_hostname "$host" "$state/$host.crt" >/dev/null 2>&1 ||
      ! openssl x509 -checkend 86400 -noout -in "$state/$host.crt" >/dev/null; then
    mkcert -cert-file "$state/$host.crt" -key-file "$state/$host.key" "$host"
  fi
  k -n "$ns" create secret tls endpoint-tls --cert="$state/$host.crt" --key="$state/$host.key" --dry-run=client -o yaml | apply
  cat <<YAML | apply
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: endpoint
  namespace: $ns
  annotations: {traefik.ingress.kubernetes.io/router.entrypoints: websecure}
spec:
  ingressClassName: traefik
  tls: [{hosts: [$host], secretName: endpoint-tls}]
  rules:
    - host: $host
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: {service: {name: $service, port: {number: 80}}}
YAML
}
if [[ $interactive == https://dex.sigstore.local ]]; then
  k -n sigstore-oidc create secret generic dex-config --from-file=config.json="$state/dex.json" --dry-run=client -o yaml | apply
  k apply -f "$values/dex.yaml"
  route sigstore-oidc dex.sigstore.local dex
  k -n sigstore-oidc rollout status deployment/dex --timeout=3m
fi
if bundled_registry; then
  k -n sigstore-registry create secret generic registry-auth --from-file="$state/htpasswd" --dry-run=client -o yaml | apply
  k apply -f "$values/registry.yaml"
  route sigstore-registry registry.local registry
  k -n sigstore-registry rollout status deploy/registry --timeout=3m
  # Scope the node resolver and TLS trust to this registry authority.
  for node in $(kind get nodes --name "$cluster"); do
    docker exec -i "$node" sh -eu -c '
      if getent hosts registry.local >/dev/null; then
        getent hosts registry.local | awk "{print \$1}" | grep -Fx "$1" >/dev/null
      else
        echo "$1 registry.local # template-k8s-sigstore" >> /etc/hosts
      fi
      d=/etc/containerd/certs.d/registry.local
      mkdir -p "$d"
      test ! -e "$d/hosts.toml" || grep -Fx "# template-k8s-sigstore" "$d/hosts.toml" >/dev/null
      cat > "$d/sigstore-ca.crt"
      printf "%s\n" "# template-k8s-sigstore" "server = \"https://registry.local\"" "[host.\"https://registry.local\"]" "  capabilities = [\"pull\", \"resolve\"]" "  ca = \"$d/sigstore-ca.crt\"" > "$d/hosts.toml"
    ' sh "$ip" < "$ca"
  done
fi
route fulcio-system fulcio.sigstore.local fulcio-server
route rekor-system rekor.sigstore.local rekor-server
route tuf-system tuf.sigstore.local tuf
if [[ -z $(k -n rekor-system get secret rekor-signer --ignore-not-found -o name) ]]; then
  [[ ! -f $state/metadata/1.root.json ]] || fail "Restore the existing Rekor signing Secret"
  [[ -e $state/rekor.key ]] || openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$state/rekor.key"
  k -n rekor-system create secret generic rekor-signer --from-file=key.pem="$state/rekor.key"
fi
if [[ -z $(k -n fulcio-system get secret fulcio-server-secret --ignore-not-found -o name) ]]; then
  [[ ! -e $state/metadata/1.root.json ]] || fail "Restore the original Fulcio Secret"
  if [[ ! -f $state/fulcio-signing.crt ]]; then
    openssl rand -hex 32 | tr -d '\n' > "$state/fulcio.pass"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -aes-256-cbc \
      -pass "file:$state/fulcio.pass" -out "$state/fulcio-signing.key"
    openssl req -new -x509 -sha256 -days 365 -subj '/O=kind/CN=Local Fulcio signing CA' \
      -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -key "$state/fulcio-signing.key" -passin "file:$state/fulcio.pass" -out "$state/fulcio-signing.crt"
  fi
  k -n fulcio-system create secret generic fulcio-server-secret --from-file=private="$state/fulcio-signing.key" \
    --from-file=cert="$state/fulcio-signing.crt" --from-file=password="$state/fulcio.pass"
fi
if [[ -z $(k -n ctlog-system get secret ct-key-password --ignore-not-found -o name) ]]; then
  openssl rand -hex 32 | tr -d '\n' | k -n ctlog-system create secret generic ct-key-password --from-file=password=/dev/stdin
fi
oidc_ca=${OIDC_CA_FILE:-$ca}
k -n fulcio-system get cm kube-root-ca.crt -o json | jq -er '.data["ca.crt"]' > "$state/kube-ca.crt"
# The canonical service alias enables authenticated discovery for the actual cluster issuer.
jq -n --arg iss "$issuer" --arg oidc "$interactive" --rawfile ca "$oidc_ca" --rawfile kube "$state/kube-ca.crt" '
  {fulcio:{config:{contents:{OIDCIssuers:{
    "https://kubernetes.default.svc":{IssuerURL:$iss,ClientID:"sigstore",Type:"kubernetes",CACert:$kube},
    ($iss):{IssuerURL:$iss,ClientID:"sigstore",Type:"kubernetes",CACert:$kube},
    ($oidc):{IssuerURL:$oidc,ClientID:"sigstore",Type:"email",CACert:$ca}
  }}}}}' > "$state/issuers.json"
k apply -f "$values/network-policy.yaml"
h upgrade --install kind-sigstore "$scaffold" -n sigstore-system -f "$values/scaffold.yaml" -f "$state/issuers.json" "${database_values[@]}" --wait --wait-for-jobs --timeout 20m
"$module/tools/publish-trust.sh" "$interactive"
cat "$ca" > "$state/controller-ca.pem"
if [[ -n ${REGISTRY_CA_FILE:-} ]]; then cat "$REGISTRY_CA_FILE" >> "$state/controller-ca.pem"; fi
k -n sigstore-policy create cm endpoint-ca --from-file=ca.crt="$state/controller-ca.pem" --dry-run=client -o yaml | apply
h upgrade --install kind-policy "$controller" -n sigstore-policy -f "$values/controller.yaml" --wait --timeout 5m
jq -n --rawfile root "$state/metadata/1.root.json" '{apiVersion:"policy.sigstore.dev/v1alpha1",kind:"TrustRoot",metadata:{name:"sigstore-kind"},spec:{remote:{mirror:"https://tuf.sigstore.local",root:($root|@base64)}}}' | apply
k wait --for=condition=Ready trustroot/sigstore-kind --timeout=3m
sed "s|KUBE_ISSUER|$issuer|" "$values/policy.yaml" | apply
k wait --for=condition=Ready clusterimagepolicy/sigstore-kind-signer --timeout=3m
