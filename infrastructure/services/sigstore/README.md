# Private Sigstore on kind

This opt-in development overlay extends the repository’s existing `template-k8s` cluster. Traefik terminates HTTPS on the existing loopback port mapping. Fulcio issues short-lived certificates to identities from the cluster service-account issuer and a separate interactive issuer. Rekor and the Fulcio CT log use separate Trillian trees backed by MySQL. Only the `sigstore-test` namespace enforces image signatures. The stage and production overlays have no dependency on this installation.

## Inventory and prerequisites

Run from the repository root on the workstation that owns the cluster, with Bash 4+, Linux utilities (`flock`, GNU coreutils), Docker, kind, Helm 3, a compatible kubectl, mkcert, OpenSSL, jq, curl, Python 3.10+, Go and Cosign **3.1.4**. The release pipeline also uses ORAS 1.2+. On Docker Desktop the daemon must resolve and trust the selected registry from its VM. Use a workstation-accessible TLS registry if the VM cannot reach the repository’s loopback Traefik mapping. Allow space for two 5 Gi claims, supporting volumes and container images, and capacity for a MySQL container with a 1 Gi memory limit.

```bash
export S=infrastructure/services/sigstore
export KUBECONFIG="$PWD/.local/kubeconfig/dev.yaml"
export KIND_CLUSTER_NAME=template-k8s
python3 -m venv .local/sigstore-venv
source .local/sigstore-venv/bin/activate
pip install -r "$S/requirements.txt"
"$S/scripts/inspect.sh"
```

Inspect namespaces, ready nodes, workload replicas, Helm releases, default StorageClass, ingress classes, Gateway resources, certificate issuers, Docker networks and registry discovery before installation. Save the inventory as a baseline. The script requires the selected context to be `kind-$KIND_CLUSTER_NAME`, an existing Traefik Service in `traefik` and the development overlay’s port mapping. Resolve differences with the live environment before applying this profile. A disposable registry used by another Make target can have a different hostname, protocol and lifetime.

## Network and endpoint TLS

| Client | Resolution and route |
| --- | --- |
| Workstation | Explicit hosts entries to 127.0.0.1, host port 443 → kind node port 30443 → Traefik |
| Pods and cluster CI | Exact CoreDNS server block for the selected private hostnames → Traefik Service ClusterIP on 443 |
| kind containerd, bundled registry | Per-node registry.local hosts entry → Traefik ClusterIP on 443, registry-specific CA under /etc/containerd/certs.d |
| Internal services | Kubernetes Service DNS. Trillian gRPC, MySQL, Redis and CT stay internal. |

For the bundled profile, add this line to the workstation hosts file. Omit `registry.local` or `dex.sigstore.local` when using external services. Explicit entries also avoid multicast DNS ambiguity for the .local suffix.

```text
127.0.0.1 fulcio.sigstore.local rekor.sigstore.local tuf.sigstore.local dex.sigstore.local registry.local
```

Initialize or reuse the workstation mkcert CA with `mkcert -install`. Each ingress receives its own key, DNS SAN and namespaced TLS Secret. In relevant runner containers, install **only** the public `$(mkcert -CAROOT)/rootCA.pem` in the CA bundle, or set `SSL_CERT_FILE` to a bundle containing it and any other required roots. For an external registry using a separate private CA, add its public CA to the host, Docker daemon, nodes and the controller’s `endpoint-ca` bundle via `REGISTRY_CA_FILE`. The bundled registry runs inside kind, so it needs no second Docker network or host port. Nodes use kind’s containerd certs.d support. Check `docker exec NODE containerd config dump` for the active registry config path. With a pre-existing Docker registry container, retain its kind network attachment and existing per-authority containerd routing. The reference used for signing must also be usable by the admission webhook and kubelet.

CoreDNS edits are confined to a delimited server block and use an optimistic concurrency check. Set `MANAGE_CLUSTER_DNS=0` when existing DNS already resolves all selected private names to the Traefik service. Allow the CoreDNS reload interval. Registry authentication uses bcrypt htpasswd over TLS. On a Linux Docker host that needs explicit registry CA configuration, install the public CA as `/etc/docker/certs.d/registry.local/ca.crt` using the daemon’s normal trust procedure. Check `curl -i https://registry.local/v2/` for the expected authenticated registry challenge (HTTP 401).

If an existing registry already uses `registry.local`, set `USE_EXISTING_REGISTRY=1` to retain its routing, credentials and storage.

## Install

```bash
export REGISTRY=registry.local       # Or the existing TLS registry authority
# Optional existing interactive OIDC provider, registered as public client "sigstore":
# export OIDC_ISSUER=https://identity.example.org OIDC_CA_FILE=/path/to/issuer-ca.pem
"$S/scripts/install.sh"
"$S/scripts/status.sh"
```

The installer verifies package SHA-256 digests for official **scaffold 0.6.125** and **policy-controller 0.10.8** (controller 0.13.1). The scaffold lock selects Fulcio 2.11.7, Rekor 1.8.15, Trillian 0.5.0 and CT Log 0.2.71 chart versions. The Trillian-backed Rekor v1 API provides signing time and transparency evidence for this profile. The scaffold’s temporary TUF server is replaced by a read-only HTTP service serving host-signed TUF metadata over the existing ingress. Chart downloads and container pulls require upstream access unless mirrored. Signing, verification and admission use private trust services.

Helm waits for the component deployments and initialization Jobs. Namespaces, default resource limits, database access policies, the issuer configuration, persistent signing keys, trust publication and admission installation are ordered explicitly. Kubernetes OIDC discovery supplies the exact issuer. The issuer and the audience `sigstore` bind a projected token to a Fulcio certificate. A Kubernetes certificate SAN includes the namespace and service account. The development signer has the exact URI `https://kubernetes.io/namespaces/sigstore-ci/serviceaccounts/release`. Interactive Dex login uses a verified email SAN. Only the release service account is authorized for admission. Restrict access to creating Pods and TokenRequests in `sigstore-ci` to trusted operators.

When an existing policy-controller owns the cluster CRDs, installation stops before installing another controller. Integrate the private TrustRoot and authority with that controller after reviewing its global policies and webhook selectors. The dedicated namespace selector is the explicit system-workload exception. Only an administrator should extend it. Keep existing workloads in their original namespaces.

## Trust bootstrap and signing

State is under `.local/sigstore/$KIND_CLUSTER_NAME` with owner-only permissions. The Fulcio file CA, Rekor ECDSA key, CT key, TUF role keys and endpoint TLS keys have distinct purposes. Chart initialization creates the CT key and trees. The installer retains the Fulcio and Rekor keys across upgrades. The TUF publication host stores separate Ed25519 keys for root, targets, snapshot and timestamp. Only public metadata and targets go to the TUF service. Distribute `metadata/1.root.json` through an authenticated, independent channel. Confirm its SHA-256 fingerprint with the operator. Never bootstrap a runner solely by downloading a first root from the mirror.

```bash
state="$PWD/.local/sigstore/$KIND_CLUSTER_NAME"
sha256sum "$state/metadata/1.root.json"
source "$S/scripts/client.sh"
sigstore_client "$state/metadata/1.root.json"
printf 'local artifact\n' > "$state/example.txt"
cosign sign-blob --yes --oidc-disable-ambient-providers \
  --oidc-redirect-url http://localhost:5555/auth/callback \
  --signing-config "$SIGSTORE_SIGNING_CONFIG" --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --bundle "$state/example.sigstore.json" "$state/example.txt"
cosign verify-blob --trusted-root "$SIGSTORE_TRUSTED_ROOT" \
  --certificate-identity developer@sigstore.local --certificate-oidc-issuer https://dex.sigstore.local \
  --bundle "$state/example.sigstore.json" "$state/example.txt"
```

The development Dex password for `developer@sigstore.local` is in `$state/dex.password`. An existing interactive provider must return a verified email and allow the registered loopback callback. The client initializes an isolated TUF cache and requires both authenticated targets. All sign and verify commands reference those targets explicitly.

## End-to-end acceptance

```bash
"$S/scripts/e2e.sh"
"$S/scripts/inspect.sh"
```

The test runs the native sample, cross-compiles the OCI executable, pushes three distinct manifests and resolves their digests. It signs the approved image and binary, verifies the registry-hosted signature, checks the blob bundle, changes a byte sequence and requires verification to fail. It verifies that both bundles contain Rekor inclusion proofs and looks up their entries in the private log. A second short-lived token produces a valid signature from an unauthorized identity. Server-side admission must reject both that image and the unsigned control with a policy-specific error. The approved Pod must run to completion and print the expected output. Evidence stays under the printed test directory. Compare workload readiness with the baseline inventory.

With an existing registry, use `IMAGE_REPOSITORY` for an authorized repository and Docker’s existing login for pushes. For private pulls, set `PULL_CONFIG` to a **registry-scoped, read-only** dockerconfigjson file with usable credentials for the webhook and test Pod. Credential-helper references require a runner-local helper and are unsuitable for a Kubernetes pull Secret. The bundled registry uses one development publisher account; separate pull and push principals are appropriate for a shared deployment.

## CI release gate

`scripts/ci.sh` is a pipeline entry point for a trusted runner with network access to this cluster, a builder, ORAS, kubectl and Cosign. It builds and tests the sample, publishes the image and raw binary, signs and verifies both, attaches verification evidence to the immutable image and submits a Job to admission. A failed check terminates the release stage. Replace the sample build/test commands with the project’s own release commands. Use a runner isolated from untrusted pull requests.

Run the runner Pod as `release` in `sigstore-ci`. Mount its signing token using the following Pod-spec fragment. Kubernetes refreshes the token. Grant optional Job submission privileges with `kubectl apply -f "$S/overlays/dev/ci-access.yaml"`. Keep the runner’s Kubernetes API identity and its Sigstore-audience token in distinct mounts. Provide registry credentials separately, and provision `registry-pull` in the test namespace.

```yaml
serviceAccountName: release
volumes:
  - name: signing-identity
    projected:
      sources:
        - serviceAccountToken: {path: token, audience: sigstore, expirationSeconds: 600}
# Add to the trusted release container:
# volumeMounts:
#   - {name: signing-identity, mountPath: /var/run/signing, readOnly: true}
```

```bash
export TOKEN_FILE=/var/run/signing/token TUF_ANCHOR=/etc/private-sigstore/1.root.json
export SIGNER_ISSUER=https://kubernetes.default.svc.cluster.local  # match cluster discovery exactly
export SIGNER_IDENTITY=https://kubernetes.io/namespaces/sigstore-ci/serviceaccounts/release
export IMAGE_REPOSITORY=registry.local/sigstore/release RELEASE_TAG="build-$BUILD_ID"
"$S/scripts/ci.sh"
```

## Operations and recovery

- Check `scripts/status.sh` for health, private trust readiness, tree sizes, signed heads and TUF expiry. Alert on failed probes, unavailable replicas, stalled Jobs, PVC pressure, unexpected key fingerprints, decreasing tree sizes or conflicting roots at the same tree size. Collect Rekor and CT signed heads outside the cluster. Bundle verification authenticates per-signature evidence. A production monitor should independently verify successive signed checkpoints and Merkle consistency proofs.
- Use `kubectl logs` for component and Job logs. Fulcio and Rekor use production log formatting. Chart annotations expose metrics on Rekor 2112 and CT 6963. Limit access to internal metrics. The database and Redis ingress policies require an enforcing CNI. Standard kind networking alone should not be assumed to enforce them.
- Refresh TUF before its seven-day timestamp expiry with `scripts/publish-trust.sh "$OIDC_ISSUER"` (omit the argument for the bundled Dex). Snapshot and targets expire after 14 and 30 days. Keep the publisher state and its version counter together. Run one publisher at a time. Check that both targets initialize from a clean cache after each change.
- Back up the Fulcio, Rekor and CT signing Secrets, all tree configuration ConfigMaps, MySQL database, registry and Dex volumes, chart values, operator state and public evidence. Encrypt backups, restrict access and test coherent restoration into an isolated environment. Restore the original log state and keys as a set, check old bundles and compare independent checkpoints before reopening signing. A fresh tree or new signing key requires an explicit trust transition.
- For service-key rotation, retain old verification material with bounded validity, add new public keys and certificates to the trusted-root target, stage signer changes, publish and verify old and new bundles. The refresh script stops on unexpected key changes. For TUF root rotation produce sequential versioned roots signed by the old and new root thresholds and retain the complete root chain. Coordinate changes to the local publisher, controller, clients and independently distributed anchors before expiry. Renewing endpoint leaves uses the mkcert CA and does not require a Sigstore root rotation.
- For production use an external HA database and durable registry, a production OIDC provider, HSM/KMS-backed signing, offline threshold TUF roots and delegated online roles, managed TLS renewal, secret encryption and audit logging. Plan log sharding, tree retention, independent witnesses, disaster recovery and highly available fail-closed admission. The single-workstation publisher and local development passwords have a narrower trust boundary.

## Troubleshooting and cleanup

A TLS hostname error usually indicates that the client resolves the name to the wrong ingress or lacks the endpoint CA. Compare DNS inside a runner with the Traefik ClusterIP. For a pending PVC inspect the default provisioner and scheduling events. For a stalled CT job inspect Fulcio readiness, tree IDs and Trillian connectivity. For an OIDC failure compare discovery issuer, audience and verified SAN. For admission errors distinguish registry authorization, private TrustRoot readiness, identity mismatch and missing OCI referrers. Preserve exact digests and bundle JSON during diagnosis.

For removal, archive the state and PVC contents first. Delete the named policy and TrustRoot, then uninstall `kind-policy` from `sigstore-policy` and `kind-sigstore` from `sigstore-system`. Review **all** ClusterImagePolicies and TrustRoots before uninstalling the controller because its Helm release owns their CRDs. Inspect namespaces with `kubectl get ns -l sigstore.local/owner=template-k8s`; deleting those namespaces deletes the associated local storage. Remove only the marked CoreDNS block with `python3 "$S/scripts/dns.py" "kind-$KIND_CLUSTER_NAME" remove unused`. On each kind node remove the marked registry.local hosts entry and the two profile-owned files in `/etc/containerd/certs.d/registry.local`. Remove only the corresponding workstation hosts entries and dedicated registry trust file. Retain the shared mkcert CA if other services use it. The cluster and Traefik remain available throughout.

## References

- [Sigstore local architecture](https://blog.sigstore.dev/a-guide-to-running-sigstore-locally-f312dfac0682/)
- [Local endpoint and trust configuration](https://flxw.de/post/2022-11-10-standing-up-sigstore-locally/)
- [Official Helm charts](https://github.com/sigstore/helm-charts)
- [kind registry networking](https://kind.sigs.k8s.io/docs/user/local-registry/)
- [Sigstore signing and verification](https://docs.sigstore.dev/)
