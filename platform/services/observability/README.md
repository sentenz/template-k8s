# Observability

The observability platform service provides a three-signal telemetry stack for Kubernetes workloads:

- **kube-prometheus-stack** — Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, Kubernetes dashboards, and alerting rules.
- **Loki** — cluster and application log storage/query.
- **Tempo** — distributed trace storage/query with service-graph and span-metric generation.
- **OpenTelemetry Collector** — node-local log collection plus OTLP ingestion for application logs, metrics, and traces.

All components are installed from pinned Helm chart versions and composed through the existing Kustomize environment overlays.

## Data flow

```text
applications -- OTLP --> OpenTelemetry Collector -- traces --> Tempo
                                         |       -- logs ----> Loki
                                         `------- metrics --> Prometheus

node container logs --> OpenTelemetry Collector --> Loki
Tempo metrics generator -------------------------> Prometheus
Prometheus + Loki + Tempo -----------------------> Grafana
```

Applications can export OTLP to either of these in-cluster endpoints:

```text
otel-collector.observability.svc.cluster.local:4317   # OTLP/gRPC
otel-collector.observability.svc.cluster.local:4318   # OTLP/HTTP
```

Grafana provisions Prometheus, Loki, and Tempo data sources. Tempo is linked to Loki for trace-to-log navigation and to Prometheus for service graphs.

## Helm charts

| Component | Chart | Version | Repository |
| --- | --- | ---: | --- |
| Metrics / dashboards / alerting | `kube-prometheus-stack` | `88.3.0` | `https://prometheus-community.github.io/helm-charts` |
| Logs | `loki` | `18.8.0` | `https://grafana-community.github.io/helm-charts` |
| Traces | `tempo` | `2.2.3` | `https://grafana-community.github.io/helm-charts` |
| Telemetry collection | `opentelemetry-collector` | `0.169.0` | `https://open-telemetry.github.io/opentelemetry-helm-charts` |

Shared chart values live under `values/`; environment capacity and retention deltas live in `overlays/{dev,stage,prod}`.

## Environment profile

| Environment | Prometheus retention | Prometheus storage | Loki storage | Tempo storage | Grafana storage |
| --- | ---: | ---: | ---: | ---: | ---: |
| `dev` | 2 days | ephemeral | ephemeral | ephemeral | ephemeral |
| `stage` | 7 days | 20 GiB | 20 GiB | 20 GiB | 5 GiB |
| `prod` | 30 days | 100 GiB | 100 GiB | 50 GiB | 10 GiB |

The stage and production profiles are intentionally conservative single-cluster defaults. Loki and Tempo use single-binary/local-persistence modes here to keep the template self-contained. Production deployments requiring high availability, multi-cluster aggregation, or higher ingestion volumes should move logs and traces to object storage and an appropriate scalable/distributed topology.

## Grafana credentials

Development creates the disposable `observability/grafana-admin` Secret with `admin-user` and `admin-password` keys.

Stage and production expect an externally managed Secret with the same contract:

| Namespace | Secret | Required keys |
| --- | --- | --- |
| `observability` | `grafana-admin` | `admin-user`, `admin-password` |

Do not commit stage or production Grafana credentials in Helm values.

## Rendering

Render from the cluster entry point, consistent with the repository deployment contract:

```bash
kustomize build clusters/dev --enable-helm --load-restrictor=LoadRestrictionsNone
kustomize build clusters/stage --enable-helm --load-restrictor=LoadRestrictionsNone
kustomize build clusters/prod --enable-helm --load-restrictor=LoadRestrictionsNone
```

## Vendoring

The repository's reproducibility contract expects third-party charts under `vendor/helm/<name>-<version>/<name>/`. Refresh the pinned observability charts with the existing generic target:

```bash
make helm-vendor HELM_CHART_NAME=kube-prometheus-stack HELM_CHART_VERSION=88.3.0 HELM_CHART_REPO=https://prometheus-community.github.io/helm-charts
make helm-vendor HELM_CHART_NAME=loki HELM_CHART_VERSION=18.8.0 HELM_CHART_REPO=https://grafana-community.github.io/helm-charts
make helm-vendor HELM_CHART_NAME=tempo HELM_CHART_VERSION=2.2.3 HELM_CHART_REPO=https://grafana-community.github.io/helm-charts
make helm-vendor HELM_CHART_NAME=opentelemetry-collector HELM_CHART_VERSION=0.169.0 HELM_CHART_REPO=https://open-telemetry.github.io/opentelemetry-helm-charts
```

Until those chart sources are vendored, Kustomize/Helm requires network access to the declared chart repositories during rendering.
