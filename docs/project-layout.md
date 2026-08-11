# Kubernetes Project Layout

This repository separates application packaging, platform services, environment configuration, and cluster composition.

```text
.
├── apps/
│   └── dependency-track/
│       ├── base/
│       └── overlays/
│           ├── dev/
│           ├── stage/
│           └── prod/
├── platform/
│   ├── postgresql/
│   │   ├── base/
│   │   └── overlays/{dev,stage,prod}/
│   └── traefik/
│       ├── base/
│       └── overlays/{dev,stage,prod}/
├── components/
├── clusters/
│   ├── dev/
│   ├── stage/
│   └── prod/
├── charts/
└── manifests/
    └── overlays/
        └── ... compatibility entry points
```

## Responsibility boundaries

- **Helm** defines the reusable workload or platform package. Environment-specific Helm values live beside the corresponding overlay.
- **Kustomize bases** contain stable Kubernetes resources that are common to all environments, such as namespaces.
- **Kustomize overlays** bind Helm releases to `dev`, `stage`, or `prod` and apply post-render patches only when a Kubernetes-level difference is clearer than a Helm value.
- **Clusters** are the canonical deployment and GitOps entry points. Each cluster composes the required application and platform overlays.
- **Components** are reserved for reusable, environment-neutral Kustomize components.
- **Charts** contains vendored or cached third-party Helm chart sources. Chart packages are not mixed with environment configuration.

The design rule is: **Helm defines what a component is; Kustomize defines how and where that component is deployed.**

## Canonical entry points

Render an entire environment from one path:

```bash
kustomize build clusters/dev --enable-helm --load-restrictor=LoadRestrictionsNone
kustomize build clusters/stage --enable-helm --load-restrictor=LoadRestrictionsNone
kustomize build clusters/prod --enable-helm --load-restrictor=LoadRestrictionsNone
```

The existing `manifests/overlays/<environment>/dependency-track` paths remain as thin compatibility wrappers so the current Make targets continue to resolve. New automation and GitOps controllers should target `clusters/<environment>`.

## Environment configuration

Values are intentionally colocated with the overlay that consumes them:

```text
apps/dependency-track/overlays/prod/
├── kustomization.yaml
└── values.yaml
```

This keeps environment deltas explicit and avoids conditional logic such as `if environment == prod` inside Helm templates.

`dev` contains local fixtures needed for a Kind-based workflow. `stage` and `prod` do not commit application or database credentials.

## Secret contract

Development uses disposable fixture credentials and the existing SOPS-encrypted TLS certificate files.

Stage and production expect externally managed Secrets:

| Namespace | Secret | Required keys | Consumer |
| --- | --- | --- | --- |
| `postgresql` | `postgresql-auth` | `postgres-password`, `password` | PostgreSQL |
| `dependency-track` | `dependency-track-database` | `username`, `password` | Dependency-Track |
| `dependency-track` | `dependency-track-kek` | `kek` | Dependency-Track |
| `dependency-track` | `dependency-track-tls` | `tls.crt`, `tls.key` | Ingress TLS |

These Secrets can be supplied by an external-secret controller, SOPS/Flux, Sealed Secrets, Vault, or a cloud secret manager. Plaintext production credentials should not be added to Helm values.

## Adding an application

1. Create `apps/<name>/base` for stable Kubernetes resources.
2. Add `apps/<name>/overlays/{dev,stage,prod}` with the Helm release and environment values.
3. Add the appropriate overlay to each `clusters/<environment>/kustomization.yaml`.
4. Put cross-cutting behavior in `components/` rather than duplicating patches.

## Adding a platform service

Use the same pattern under `platform/<name>`. Platform services include ingress controllers, databases, certificate management, external secrets, observability, and policy engines.

## Scaling beyond one cluster per environment

When multiple regions or clusters are introduced, preserve the same composition model and make the cluster identity explicit, for example:

```text
clusters/
├── dev-eu-central-1-01/
├── stage-eu-central-1-01/
├── prod-eu-central-1-01/
└── prod-us-east-1-01/
```

Application and platform overlays remain reusable, while cluster directories capture only cluster-specific composition and deltas.
