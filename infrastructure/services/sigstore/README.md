# Sigstore

Sigstore is modeled as an infrastructure-managed platform capability and therefore lives under `infrastructure/services/`. It provides self-hosted, cryptographically verifiable signing and verification of software artifacts and OCI container images.

## 1. Components

| Component    | Namespace         | Role                                                                                                                   |
| ------------ | ----------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Fulcio**   | `fulcio-system`   | Free code-signing Certificate Authority. Issues short-lived signing certificates to identities authenticated via OIDC. |
| **ctlog**    | `ctlog-system`    | Fulcio's Certificate Transparency log (a Trillian-backed log of issued certificates).                                  |
| **Rekor**    | `rekor-system`    | Transparency log and timestamping server for signatures and attestations.                                              |
| **Trillian** | `trillian-system` | Append-only, verifiable log backend shared by Rekor and ctlog (log server + log signer).                               |
| **MySQL**    | `mysql-sigstore`  | Dedicated database for the Trillian log and the Rekor search index.                                                    |

```plaintext
cosign ──OIDC──▶ Fulcio ──issues cert──▶ ctlog (Trillian log)
   │
   └──signs/attests──▶ Rekor ──appends entry──▶ Trillian log ──▶ MySQL
```

The base owns the four Sigstore namespaces (`fulcio-system`, `ctlog-system`, `rekor-system`, `trillian-system`). Each environment overlay owns the two Helm releases (`fulcio`, `rekor`) and their values. The `rekor` release pulls in the `trillian` subchart; the `fulcio` release pulls in the `ctlog` subchart.

## 2. Details

### 2.1 Insights

- The Sigstore charts are **MySQL-only**: Trillian's `--storage_system`/`--mysql_uri` arguments and Rekor's `--search_index.*` arguments only wire MySQL DSNs. The dedicated `mysql-sigstore` instance is therefore MySQL rather than the shared PostgreSQL used by Dependency-Track.
- Fulcio uses the `fileca` certificate authority: the chart's `createcerts` Job generates a short-lived CA and key on first deploy. KMS-backed signing (AWS/GCP) is out of scope.
- The `sigstore-mysql` Secret bridges the dedicated MySQL credentials into the key names the charts expect (`mysql-user`, `mysql-password`, `mysql-database`). It is created in **both** `rekor-system` and `trillian-system` because the Rekor server and the Trillian log server/signer each reference it via a namespace-scoped `secretKeyRef`.
- **`createcerts` is a regular Job (not a Helm hook) with `ttlSecondsAfterFinished: 3600`**, so it re-runs on every re-deploy and **regenerates the Fulcio CA**. The ctlog's trusted root (`ctlog-secret`) is only refreshed when the `fulcio-ctlog-createctconfig` Job runs, so after a CA rotation the CT log rejects new certificates ("Error entering certificate in CTL"). If signing starts failing after a re-deploy, re-run `createctconfig` and restart the ctlog Deployment (see Troubleshooting). A stable, pre-seeded CA (with `createcerts.enabled: false`) is the recommended fix for anything beyond throwaway dev.
- Fulcio's default config only trusts the issuer `https://kubernetes.default.svc` (and the `https://kubernetes.*.svc` meta-issuer). This cluster mints ServiceAccount tokens with issuer `https://kubernetes.default.svc.cluster.local`, so the dev overlay adds that issuer under `config.contents.OIDCIssuers`.

### 2.2 Instructions

```bash
make k8s-deploy K8S_ENV=dev
make k8s-destroy K8S_ENV=dev
```

### 2.3 Usage

Keyless signing uses a **Kubernetes ServiceAccount token** as the OIDC identity — no external identity provider is needed. The base defines the `cosign-dev` ServiceAccount in `fulcio-system`; Fulcio's config trusts Kubernetes SA tokens.

The Makefile wraps the whole flow (cosign 3.x, config-based):

```bash
# Sign an image (mints a fresh SA token, builds the signing config + trusted root)
make sast-cosign-sign <image>

# Verify a signature against the self-hosted Rekor log, asserting the SA identity
make sast-cosign-verify-image <image>
```

What the targets do under the hood:

1. `sast-cosign-trust-bundle` — concatenates the self-signed `fulcio.localhost` + `rekor.localhost` ingress certs into `logs/sast/sigstore-ingress-ca.pem` (passed to cosign via `SSL_CERT_FILE`).
2. `sast-cosign-signing-config` — `cosign signing-config create` pointing at the self-hosted Fulcio/Rekor endpoints and the cluster OIDC issuer (cosign 3.x `sign` no longer accepts `--fulcio-url`/`--rekor-url`).
3. `sast-cosign-trusted-root` — builds a Sigstore TrustedRoot JSON bundling the Fulcio CA, the Rekor public key, and the CT-log (ctlog) public key.
4. `sast-cosign-sign` — mints a token with `--audience=sigstore` and runs `cosign sign --signing-config … --trusted-root … --identity-token …`.
5. `sast-cosign-verify-image` — `cosign verify --trusted-root … --certificate-identity https://kubernetes.io/namespaces/fulcio-system/serviceaccounts/cosign-dev --certificate-oidc-issuer https://kubernetes.default.svc.cluster.local …`.

> The signing identity is the ServiceAccount, not a person: any workload that can mint a token for `cosign-dev` can sign as it. For CI, prefer an in-cluster Job with a projected, audience-restricted token (`audience: sigstore`) rather than manually minted tokens.

## 3. Stage and production secrets

Stage and production expect the following Secrets to be supplied externally:

| Namespace         | Secret                | Required keys                                    | Consumer                   |
| ----------------- | --------------------- | ------------------------------------------------ | -------------------------- |
| `mysql-sigstore`  | `mysql-sigstore-auth` | `mysql-root-password`, `mysql-password`          | MySQL                      |
| `rekor-system`    | `sigstore-mysql`      | `mysql-user`, `mysql-password`, `mysql-database` | Rekor search index         |
| `trillian-system` | `sigstore-mysql`      | `mysql-user`, `mysql-password`, `mysql-database` | Trillian log server/signer |
| `fulcio-system`   | `fulcio-tls`          | `tls.crt`, `tls.key`                             | Fulcio ingress TLS         |
| `rekor-system`    | `rekor-tls`           | `tls.crt`, `tls.key`                             | Rekor ingress TLS          |

## 4. Troubleshooting

```bash
kubectl --kubeconfig=.local/kubeconfig/dev.yaml get pods -A
kubectl --kubeconfig=.local/kubeconfig/dev.yaml get pods -n fulcio-system -n rekor-system -n trillian-system -n ctlog-system -n mysql-sigstore

# Fulcio health
curl -k https://fulcio.localhost/api/v2/ctfe

# Rekor log info
curl -k https://rekor.localhost/api/v1/log
```

Watch the one-shot Jobs to completion: `createcerts` (Fulcio CA), `createtree` (Rekor + ctlog logs), and `createdb` (Trillian schema).

**Signing fails with "Error entering certificate in CTL" after a re-deploy** — the `createcerts` Job rotated the Fulcio CA but the ctlog still trusts the old root. Resync the CT log:

```bash
kubectl --kubeconfig=.local/kubeconfig/dev.yaml delete job fulcio-ctlog-createctconfig -n ctlog-system
echo "yes-dev" | make k8s-deploy K8S_ENV=dev   # re-creates the createctconfig Job
kubectl --kubeconfig=.local/kubeconfig/dev.yaml rollout restart deployment/ctlog -n ctlog-system
```

Confirm the ctlog now trusts the current CA (fingerprints should match):

```bash
kubectl get secret ctlog-secret -n ctlog-system -o jsonpath='{.data.fulcio-1}' | base64 -d | openssl x509 -noout -fingerprint -sha256
kubectl get secret fulcio-server-secret -n fulcio-system -o jsonpath='{.data.cert}' | base64 -d | openssl x509 -noout -fingerprint -sha256
```
