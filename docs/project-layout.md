# Kubernetes Project Layout

This repository separates application packaging, platform services, environment configuration, cluster composition, and third-party dependencies.

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
│   │   ├── kind-cluster.yaml
│   │   ├── kustomization.yaml
│   │   ├── dependency-track.localhost+1.pem.enc
│   │   └── dependency-track.localhost+1-key.pem.enc
│   ├── stage/
│   │   └── kustomization.yaml
│   └── prod/
│       └── kustomization.yaml
└── vendor/
    └── helm/
        ├── dependency-track-2.0.0/dependency-track/
        ├── postgresql-18.8.5/postgresql/
        └── traefik-41.1.0/traefik/
```

Generated local runtime state is not part of the declarative repository tree. The Make workflow stores kubeconfigs under `.local/kubeconfig/<environment>.yaml`, and `.local/` is ignored by Git.

## Responsibility boundaries

- **Helm** defines the reusable workload or platform package. Environment-specific Helm values live beside the corresponding overlay.
- **Kustomize bases** contain stable Kubernetes resources that are common to all environments, such as namespaces.
- **Kustomize overlays** bind Helm releases to `dev`, `stage`, or `prod` and apply post-render patches only when a Kubernetes-level difference is clearer than a Helm value.
- **Clusters** are the only deployment and GitOps entry points. Each cluster composes the required application and platform overlays plus cluster-local resources and, where applicable, cluster-creation configuration.
- **Components** are reserved for reusable, environment-neutral Kustomize components.
- **Vendor** contains immutable third-party sources. `vendor/helm/` holds the upstream Helm chart copies used by Kustomize and must not contain environment configuration.

The design rule is: **Helm defines what a component is; Kustomize defines how and where that component is deployed.**

## Canonical entry points

Render an entire environment from one path:

```bash
kustomize build clusters/dev --enable-helm --load-restrictor=LoadRestrictionsNone
kustomize build clusters/stage --enable-helm --load-restrictor=LoadRestrictionsNone
kustomize build clusters/prod --enable-helm --load-restrictor=LoadRestrictionsNone
```

All deployment, render, CI, and GitOps automation should target `clusters/<environment>`. Application and platform overlays are composition inputs rather than independent deployment entry points.

The Make interface uses the same boundary. `K8S_ENV` defaults to `dev`, `K8S_CLUSTER_PATH` resolves to `clusters/$(K8S_ENV)`, generated kubeconfig state resolves to `.local/kubeconfig/$(K8S_ENV).yaml`, and rendered output is written to `render/kustomize/$(K8S_ENV).yaml`.

## Vendored Helm dependencies

Third-party Helm charts live under `vendor/helm/` rather than under applications, platform services, or clusters. This makes the ownership boundary explicit: overlays configure a dependency, but they do not own a copy of its upstream source.

The version wrapper directories are intentional. When a Kustomize `helmCharts` entry contains both `repo` and `version`, Kustomize looks for the local chart at:

```text
<chartHome>/<name>-<version>/<name>
```

For example, the Traefik overlays declare `chartHome: ../../../../vendor/helm`, `name: traefik`, and `version: 41.1.0`, so the vendored chart must be present at:

```text
vendor/helm/traefik-41.1.0/traefik/
```

Keep vendored chart source immutable. Environment changes belong in overlay `values.yaml` files or Kustomize patches. If a chart itself needs source changes, maintain an explicit fork rather than editing the vendored copy.

Renovate continues to update the `helmCharts.version` declarations under `apps/` and `platform/`; `vendor/**` is excluded from Renovate mutation. A dependency-update change must therefore refresh the matching vendored chart as part of the same change. Use:

```bash
make helm-vendor \
  HELM_CHART_NAME=traefik \
  HELM_CHART_VERSION=41.1.0 \
  HELM_CHART_REPO=https://traefik.github.io/charts
```

See `vendor/helm/README.md` for the vendor contract and refresh procedure.

## Development cluster

The development environment is backed by Kind. Its version-controlled cluster topology is therefore colocated with its composition at `clusters/dev/kind-cluster.yaml`. This file defines the Kind node topology and local host port mappings, while `clusters/dev/kustomization.yaml` defines what is deployed into that cluster.

Cluster-specific TLS fixtures also remain under `clusters/dev` because their certificate and hostname are properties of the development cluster composition rather than the reusable application overlay.

The resulting boundary is:

```text
clusters/dev/
├── kind-cluster.yaml        # how the dev Kubernetes cluster is created
├── kustomization.yaml       # what is deployed into the dev cluster
└── *.enc                    # encrypted dev-only cluster fixtures
```

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

Development uses disposable fixture credentials and the existing SOPS-encrypted TLS certificate files under `clusters/dev`.

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

Application and platform overlays remain reusable, while cluster directories capture only cluster-specific composition and deltas. Cluster-creation files such as Kind configuration should only be present for cluster implementations that use them.
