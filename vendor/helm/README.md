# Vendored Helm Charts

This directory contains immutable copies of third-party Helm charts consumed by Kustomize.

## Layout

Kustomize's Helm inflator resolves a chart with both `repo` and `version` configured as:

```text
vendor/helm/<name>-<version>/<name>/
```

Keep that version wrapper even though the chart's own `Chart.yaml` also contains the version. It is part of Kustomize's local-chart lookup convention and allows Kustomize to use the vendored chart instead of pulling it again.

Current dependencies are:

```text
vendor/helm/
├── dependency-track-2.0.0/dependency-track/
├── postgresql-18.8.5/postgresql/
└── traefik-41.1.0/traefik/
```

## Ownership

Treat everything below `vendor/helm/` as upstream source:

- do not hand-edit vendored chart templates or default values;
- configure charts through `apps/<name>/overlays/<env>/values.yaml` or `platform/<category>/<name>/overlays/<env>/values.yaml`;
- use Kustomize patches for Kubernetes-level changes that are clearer after Helm rendering;
- maintain forks outside this vendor tree if an upstream chart itself must be changed.

Renovate updates the `helmCharts.version` declarations under `apps/` and `platform/`. The matching vendored chart must be refreshed in the same dependency-update change so repository builds remain reproducible and do not fall back to an upstream chart download.

## Refreshing a chart

Use the generic Make target with the same name, version, and repository declared in the consuming Kustomization:

```bash
make helm-vendor \
  HELM_CHART_NAME=traefik \
  HELM_CHART_VERSION=41.1.0 \
  HELM_CHART_REPO=https://traefik.github.io/charts
```

The target replaces existing vendored versions of that chart and writes the Kustomize-compatible `<name>-<version>/<name>` layout under `vendor/helm/`.
