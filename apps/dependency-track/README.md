# Dependency-Track

Dependency-Track is the application workload in this template. The upstream Helm chart defines the workload; Kustomize overlays bind it to an environment.

```text
dependency-track/
├── base/
│   ├── kustomization.yaml
│   └── namespace.yaml
└── overlays/
    ├── dev/
    ├── stage/
    └── prod/
```

- [1. Details](#1-details)
  - [1.1. Insights](#11-insights)
- [2. Development](#2-development)
- [3. Stage and production secrets](#3-stage-and-production-secrets)
- [4. Troubleshooting](#4-troubleshooting)

## 1. Details

### 1.1. Insights

- [SBOM Organisation](docs/sbom-organisation.md)
  > Project hierarchy, release and environment modelling, metadata conventions, and access-control model for Dependency-Track.

## 2. Development

The development overlay is intended for the local Kind workflow. It uses disposable database credentials and a development-only KEK fixture. Cluster-local topology and TLS material are owned by `clusters/dev`. Encrypted TLS fixtures live in `clusters/dev/apps/secrets/`, beneath the application composition that consumes them.

Before rendering the dev environment, decrypt the certificate fixtures:

```bash
make secrets-sops-decrypt \
  clusters/dev/apps/secrets/dependency-track.localhost+1.pem.enc \
  clusters/dev/apps/secrets/dependency-track.localhost+1-key.pem.enc
```

Decryption writes sibling `.pem` files, which Git ignores. Kustomize does not decrypt SOPS files: `clusters/dev/apps/kustomization.yaml` reads the plaintext files and generates the `dependency-track-tls` Secret in the `dependency-track` namespace. Its stable name matches the ingress reference in the development Helm values.

Alternatively, generate a fresh local self-signed certificate without accessing the encrypted fixtures:

```bash
make cert-certificate-generate CERT_HOSTNAME=dependency-track.localhost
```

`CERT_DIR` defaults to `$(K8S_CLUSTER_PATH)/apps/secrets`; override it when generating material for another consuming Kustomization. The Kind CI action generates an ephemeral pair at the same location, uses the certificate for its HTTPS checks, and restores any pre-existing plaintext files during cleanup. Commit only encrypted fixtures; remove plaintext files after use. Rendered manifests also contain Secret data and must be treated as sensitive.

`clusters/dev` remains the canonical development entry point. The Kind topology for this environment is defined by `clusters/dev/kind-cluster.yaml`.

## 3. Stage and production secrets

Stage and production reference externally managed Secrets rather than committing credentials into Helm values:

- `dependency-track-database` with keys `username` and `password`.
- `dependency-track-kek` with key `kek`.
- `dependency-track-tls` as a `kubernetes.io/tls` Secret.

All three Secrets must exist in the `dependency-track` namespace before the application becomes ready, unless an external-secret or certificate controller creates them declaratively.

## 4. Troubleshooting

Inspect the local development workload:

```bash
kubectl --kubeconfig=.local/kubeconfig/dev.yaml -n dependency-track get ingress
kubectl --kubeconfig=.local/kubeconfig/dev.yaml -n dependency-track get pods
kubectl --kubeconfig=.local/kubeconfig/dev.yaml -n dependency-track get secrets
```

For local path-based routing:

```bash
curl -I -k --max-time 15 https://dependency-track.localhost/
curl -I -k --max-time 15 https://dependency-track.localhost/api
curl -I -k --max-time 15 https://dependency-track.localhost/health
```
