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
  - [1.2. Instructions](#12-instructions)
  - [1.3. Usage](#13-usage)
- [2. Development](#2-development)
- [3. Stage and production secrets](#3-stage-and-production-secrets)
- [4. Troubleshooting](#4-troubleshooting)

## 1. Details

### 1.1. Insights

- [SBOM Organisation](docs/sbom-organisation.md)
  > Project hierarchy, release and environment modelling, metadata conventions, and access-control model for Dependency-Track.

### 1.2. Instructions

- Deploy Workloads
  > Deploy the Dependency-Track workloads to the current environment.

  ```bash
  make k8s-deploy
  ```

- Destroy Workloads
  > Destroy the Dependency-Track workloads in the current environment.

  ```bash
  make k8s-destroy
  ```

### 1.3. Usage

1. Development Environment (Dev)

    - Port Forwarding
      > Access the Dependency-Track application in the current environment.

      ```bash
      kubectl --kubeconfig=.local/kubeconfig/dev.yaml -n dependency-track port-forward svc/dependency-track 8080:8080
      ```

    - Browser Access
      > Access the Dependency-Track application in the browser for the current environment.

      ```bash
      https://dependency-track.localhost
      ```

## 2. Development

The development overlay is intended for the local Kind workflow. It uses disposable database credentials and a development-only KEK fixture. Cluster-local topology and TLS material are owned by `clusters/dev`.

Before rendering the dev environment, decrypt the certificate fixtures:

```bash
make secrets-sops-decrypt \
  clusters/dev/secrets/dependency-track.localhost+1.pem.enc \
  clusters/dev/secrets/dependency-track.localhost+1-key.pem.enc
```

The `clusters/dev` kustomization generates the `dependency-track-tls` Secret from the decrypted files and is the canonical development entry point. The Kind topology for this environment is defined by `clusters/dev/kind-cluster.yaml`.

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
curl -I -k --max-time 15 https://dependency-track.localhost/api/version
curl -I -k --max-time 15 https://dependency-track.localhost/health/ready
```

The chart routes `/api` to the api-server, but the bare `/api` path is not a guaranteed application endpoint. Use `/api/version` when validating API reachability.
