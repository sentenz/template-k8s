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

## Development

The development overlay is intended for the local Kind workflow. It uses disposable database credentials and a development-only KEK fixture. Cluster-local TLS material is owned by `clusters/dev`.

Before rendering the dev environment, decrypt the certificate fixtures:

```bash
make secrets-sops-decrypt \
  clusters/dev/dependency-track.localhost+1.pem.enc \
  clusters/dev/dependency-track.localhost+1-key.pem.enc
```

The `clusters/dev` kustomization generates the `dependency-track-tls` Secret from the decrypted files and is the canonical development entry point.

## Stage and production secrets

Stage and production reference externally managed Secrets rather than committing credentials into Helm values:

- `dependency-track-database` with keys `username` and `password`.
- `dependency-track-kek` with key `kek`.
- `dependency-track-tls` as a `kubernetes.io/tls` Secret.

All three Secrets must exist in the `dependency-track` namespace before the application becomes ready, unless an external-secret or certificate controller creates them declaratively.

## Troubleshooting

Inspect the workload:

```bash
kubectl --kubeconfig=config/kubeconfig.yaml -n dependency-track get ingress
kubectl --kubeconfig=config/kubeconfig.yaml -n dependency-track get pods
kubectl --kubeconfig=config/kubeconfig.yaml -n dependency-track get secrets
```

For local path-based routing:

```bash
curl -I -k --max-time 15 https://dependency-track.localhost/
curl -I -k --max-time 15 https://dependency-track.localhost/api
curl -I -k --max-time 15 https://dependency-track.localhost/health
```
