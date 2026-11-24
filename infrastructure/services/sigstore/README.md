# Private Sigstore on kind

The development Kustomize composition includes Sigstore. The standard `make k8s-deploy K8S_ENV=dev` command applies the pinned scaffold and Policy Controller charts, the TUF mirror, the OCI registry, and the Traefik routes. The stage and production compositions are independent of this development overlay.

## Prerequisites and networking

Use the existing kind cluster with Traefik’s HTTPS NodePort 30443 mapped to host loopback port 443, a default StorageClass, and the repository’s usual development configuration and Secrets. Install Docker, kubectl, GNU Make, Bash, jq, OpenSSL, mkcert, flock and htpasswd. Signing uses Cosign 3.1.4. TUF publication uses a TUF repository publisher such as [tuftool](https://github.com/awslabs/tough/tree/develop/tuftool).

Set `K8S_KUBECONFIG` and `KIND_CLUSTER_NAME` on the Make command line when using a different kubeconfig or cluster. Confirm that the existing cluster, ingress and storage are available.

```bash
kind get clusters
kubectl --kubeconfig .local/kubeconfig/dev.yaml get nodes,ingressclass,storageclass
kubectl --kubeconfig .local/kubeconfig/dev.yaml -n traefik get service traefik
mkcert -install
```

| Clients | Route |
| --- | --- |
| Workstation | Map private hostnames to `127.0.0.1` in the workstation hosts file. Traefik serves TLS over the existing kind port mapping. |
| Pods and CI | Resolve the private hostnames to the Traefik Service ClusterIP. |
| kind image pulls | Configure `registry.local` resolution and CA trust in each node’s containerd registry configuration. |

Add this entry to the workstation hosts file.

```text
127.0.0.1 fulcio.sigstore.local rekor.sigstore.local tuf.sigstore.local registry.local
```

Use existing private DNS or append a separate zone block to the CoreDNS Corefile. Replace `TRAEFIK_SERVICE_IP` with the ClusterIP of `traefik/traefik`. Retain the existing CoreDNS blocks and allow the normal reload interval.

```text
fulcio.sigstore.local rekor.sigstore.local tuf.sigstore.local registry.local {
    hosts {
        TRAEFIK_SERVICE_IP fulcio.sigstore.local rekor.sigstore.local tuf.sigstore.local registry.local
        ttl 30
    }
}
```

Add `TRAEFIK_SERVICE_IP registry.local` to each kind node’s hosts file when the node resolver does not already resolve that hostname. Copy the public mkcert CA to `/etc/containerd/certs.d/registry.local/ca.crt` on each node. Set this authority-specific `hosts.toml` when the node does not already have a registry configuration. Use the existing registry configuration for other authorities.

```toml
server = "https://registry.local"
[host."https://registry.local"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/registry.local/ca.crt"
```

Docker clients may also need the CA under the daemon’s `/etc/docker/certs.d/registry.local/`. Install the public CA in any CI runner trust store. The bundled registry runs in kind. An organization registry can be used for signing and image pulls if all clients and the webhook can reach it and trust its CA. Supply registry-scoped pull credentials in the test workload’s `imagePullSecrets`.

## Deploy and publish private TUF

```bash
make k8s-deploy K8S_ENV=dev
```

On first deployment, Make creates the runtime Secrets and generates per-host endpoint certificates signed by the workstation CA. Fulcio’s CA, Rekor’s signing key, the CT Log credentials and the database credentials are independent. The CT Log and Rekor share a dedicated Trillian database with separate trees. Signing keys and database credentials persist in Kubernetes Secrets across redeployments.

The first run starts the backends and creates the TUF mirror workload. The mirror becomes ready once signed metadata is available. Wait for Fulcio, Rekor and CT Log to become ready before building the TUF targets.

```bash
export KUBECONFIG="$PWD/.local/kubeconfig/dev.yaml"
export SIGSTORE_STATE="$PWD/.local/sigstore/template-k8s"
export SSL_CERT_FILE="$(mkcert -CAROOT)/rootCA.pem"
umask 077
mkdir -p "$SIGSTORE_STATE/targets"
kubectl -n fulcio-system rollout status deployment/fulcio-server
kubectl -n rekor-system rollout status deployment/rekor-server
kubectl -n ctlog-system rollout status deployment/ctlog
kubectl -n fulcio-system get secret fulcio-server-secret -o jsonpath='{.data.cert}' |
  base64 -d > "$SIGSTORE_STATE/fulcio.pem"
kubectl -n ctlog-system get secret ctlog-public-key -o jsonpath='{.data.public}' |
  base64 -d > "$SIGSTORE_STATE/ctfe.pub"
curl --fail --cacert "$SSL_CERT_FILE" https://rekor.sigstore.local/api/v1/log/publicKey \
  > "$SIGSTORE_STATE/rekor.pub"
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cosign trusted-root create \
  --fulcio="url=https://fulcio.sigstore.local,certificate-chain=$SIGSTORE_STATE/fulcio.pem" \
  --rekor="url=https://rekor.sigstore.local,public-key=$SIGSTORE_STATE/rekor.pub,start-time=$start" \
  --ctfe="url=http://ctlog.ctlog-system.svc/sigstorescaffolding,public-key=$SIGSTORE_STATE/ctfe.pub,start-time=$start" \
  --out "$SIGSTORE_STATE/targets/trusted_root.json"
cosign signing-config create \
  --fulcio="url=https://fulcio.sigstore.local,api-version=1,start-time=$start,operator=kind" \
  --rekor="url=https://rekor.sigstore.local,api-version=1,start-time=$start,operator=kind" --rekor-config ANY \
  --out "$SIGSTORE_STATE/targets/signing_config.v0.2.json"
```

Create and sign a TUF repository with the two targets above. The following development example uses separate keys for each TUF role. Run root creation once, then retain the keys and root for subsequent publication. The signed repository contains `metadata/1.root.json`, `metadata/timestamp.json`, snapshot and targets metadata, plus the two files under `targets/`. Keep all keys outside the published repository.

```bash
mkdir -p "$SIGSTORE_STATE/tuf-keys"
root="$SIGSTORE_STATE/root.json"
tuftool root init "$root"
tuftool root expire "$root" 'in 1 year'
keys=()
for role in root targets snapshot timestamp; do
  key="$SIGSTORE_STATE/tuf-keys/$role.pem"
  tuftool root set-threshold "$root" "$role" 1
  tuftool root gen-rsa-key "$root" "$key" --role "$role"
  keys+=(--key "$key")
done
tuftool root sign "$root" --key "$SIGSTORE_STATE/tuf-keys/root.pem"
tuftool create --root "$root" "${keys[@]}" --add-targets "$SIGSTORE_STATE/targets" \
  --targets-version 1 --targets-expires 'in 30 days' \
  --snapshot-version 1 --snapshot-expires 'in 14 days' \
  --timestamp-version 1 --timestamp-expires 'in 7 days' \
  --outdir "$SIGSTORE_STATE/tuf"
cp "$root" "$SIGSTORE_STATE/tuf/metadata/1.root.json"
make k8s-deploy K8S_ENV=dev
```

Make publishes the signed files, waits for the TUF service and controller, and applies private trust and signature policy. Use `SIGSTORE_TUF_REPO=/path/to/repository` to publish a repository from another signing environment. Run `make k8s-sigstore-status` to check endpoint and policy readiness. Only the `sigstore-test` namespace uses the image admission policy.

## End-to-end verification

The cluster’s service-account issuer supplies the OIDC identity. Fulcio accepts short-lived tokens with audience `sigstore` using its Kubernetes issuer type. The overlay explicitly configures both the chart’s built-in issuer `https://kubernetes.default.svc` and kind’s fully qualified variant `https://kubernetes.default.svc.cluster.local`. The deploy target checks which issuer the cluster advertises and admission requires that exact issuer and the release service-account identity.

An operator with TokenRequest access can mint a token from a workstation. A CI job can pass the file containing a projected token. Both use `--identity-token`, so the signing configuration contains only the Fulcio and Rekor endpoints. The certificate identifies the service account. Restrict access to TokenRequests for `release` and to creating Pods that use it.


Distribute `1.root.json` independently and verify its SHA-256 fingerprint before trusting the mirror. Use a private cache and the targets authenticated by Cosign. Replace the root path on runners with the independently distributed file.

```bash
export TUF_ROOT="$(mktemp -d)"
mirror=https://tuf.sigstore.local
cosign initialize --mirror "$mirror" --root "$SIGSTORE_STATE/tuf/metadata/1.root.json"
trusted=$(find "$TUF_ROOT" -path '*/targets/trusted_root.json' -type f)
signing=$(find "$TUF_ROOT" -path '*/targets/signing_config.v0.2.json' -type f)
test -f "$trusted" && test -f "$signing"
issuer=$(kubectl get --raw /.well-known/openid-configuration | jq -er .issuer)
identity=https://kubernetes.io/namespaces/sigstore-ci/serviceaccounts/release
token="$SIGSTORE_STATE/release.token"
kubectl -n sigstore-ci create token release --audience sigstore --duration 10m |
  tr -d '\n' > "$token"
sign=(--yes --oidc-disable-ambient-providers --identity-token "$token" --signing-config "$signing" --trusted-root "$trusted")
verify=(--trusted-root "$trusted" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer")
```

Build the sample from `infrastructure/services/sigstore/sample`. Copy its Dockerfile and build a Linux executable named `hello` into the same temporary build context. Push to an OCI registry, then resolve the exact digest from the registry using `oras resolve`. For the bundled registry, authenticate as `publisher` using `$SIGSTORE_STATE/registry.password`. Provision a registry pull Secret in `sigstore-test` before validating admission.

```bash
cosign sign "${sign[@]}" --bundle image.sigstore.json "$SIGNED_IMAGE_DIGEST"
cosign verify "${verify[@]}" "$SIGNED_IMAGE_DIGEST"
cosign sign-blob "${sign[@]}" --bundle artifact.sigstore.json hello
cosign verify-blob "${verify[@]}" --bundle artifact.sigstore.json hello
cp hello hello.modified
printf 'modified\n' >> hello.modified
! cosign verify-blob "${verify[@]}" --bundle artifact.sigstore.json hello.modified
rm -f "$token"
```

The automated verification checks accept already published image digests and a signed blob bundle.

```bash
make k8s-sigstore-test SIGNED_IMAGE="$SIGNED_IMAGE_DIGEST" \
  UNSIGNED_IMAGE="$UNSIGNED_IMAGE_DIGEST" ARTIFACT=hello ARTIFACT_BUNDLE=artifact.sigstore.json
```

Use the bundle’s `verificationMaterial.tlogEntries[0].logIndex` to retrieve the entry from the private Rekor API at `/api/v1/log/entries?logIndex=INDEX`. Submit a Pod using the verified digest to `sigstore-test` and check that it runs. Repeat with a distinct unsigned digest and with a digest signed by the `unapproved` account. Each negative case should fail admission with the `sigstore-kind-signer` policy. Use `kubectl run --dry-run=server` to exercise the admission policy without starting a Pod.

In CI, run build and tests, publish by digest, then sign and verify using the same private TUF targets. Run the trusted runner as `sigstore-ci/release` and project a service account token with audience `sigstore` and expiration `600` seconds. Pass its mounted path to Cosign. Publish the OCI signature and the artifact bundle with verification evidence. Submit the deployment by digest only after signature verification succeeds. The optional `overlays/dev/ci-access.yaml` grants the release service account access to submit and observe test Jobs.

## Operations

- Inspect the certificate issuance, CT and Rekor deployments, log initialization Jobs, database and PVCs through kubectl. Rekor exposes metrics on 2112 and CT Log on 6963. Monitor signed tree heads and consistency proofs independently of the cluster. NetworkPolicy enforcement depends on the CNI.
- Refresh signed timestamp metadata before expiry. Increment metadata versions, use the original root and role keys, and rerun the standard deploy command to publish. Distribute root rotations using a sequential old-key and new-key signed root chain. Retain historical verification keys when rotating Fulcio, Rekor or CT Log.
- Back up Helm values, input and signing Secrets, both tree IDs, TUF publisher state and databases or volumes. Restore keys and log data together. Avoid applying this composition over a previous Helm-managed Sigstore installation until ownership and backups have been reviewed.
- `make k8s-destroy K8S_ENV=dev` removes the development composition, including Sigstore namespaces and their state. Back up signing keys and storage first. Remove the endpoint-specific host, DNS and registry configuration separately if it is no longer needed.
- For persistent deployments, use managed TLS, production OIDC, external key protection, durable HA state, offline threshold TUF roots and independently monitored logs.

## References

- [Sigstore local architecture](https://blog.sigstore.dev/a-guide-to-running-sigstore-locally-f312dfac0682/)
- [Official Helm charts](https://github.com/sigstore/helm-charts)
- [kind registry networking](https://kind.sigs.k8s.io/docs/user/local-registry/)
