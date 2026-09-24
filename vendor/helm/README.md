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

Install the Python validation dependency first:

```bash
python3 -m pip install -r tests/manifests/requirements.txt
```

The target downloads into a temporary directory, verifies the chart name and version, and publishes the Kustomize-compatible `<name>-<version>/<name>` directory only after success. Existing versions are retained; attempting to overwrite an existing version fails. This permits development to advance while stage and production retain older versions.

Run `make helm-vendor-check` to verify every overlay reference before rendering. Remove a version only after confirming that no application or platform overlay references it. Cleanup is a separate reviewed change, never a side effect of downloading another version.

Use `make k8s-render K8S_ENV=<environment>` to render deployment configuration. The former `helm-render-*` diagnostic targets have been removed because they selected upstream defaults rather than environment values.
