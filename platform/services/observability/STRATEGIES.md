# Observability strategies

The default observability model separates service health from resource health:

- **RED** (Rate, Errors, Duration) is the default strategy for request-driven services.
- **USE** (Utilization, Saturation, Errors) is the default strategy for compute and runtime resources.
- **Availability** complements both strategies with scrape/target health and workload readiness.
- **Logs and traces** provide diagnostic context after a RED, USE, or availability signal identifies an affected service or resource.

These are baseline template conventions. Application SLOs, error budgets, and measured workload behavior should determine production thresholds.

## RED

RED should be implemented at the closest common request boundary so that every application does not need framework-specific request instrumentation merely to expose service-level health.

For HTTP workloads behind Traefik, the template uses Traefik Prometheus metrics with router and service labels enabled.

| Signal | Default measurement | Typical action |
| --- | --- | --- |
| Rate | requests per second over 5 minutes | detect traffic changes and provide alert gating |
| Errors | 5xx responses / all responses over 5 minutes | detect failed service requests |
| Duration | p95 request duration over 5 minutes | detect degraded user-facing latency |

Recommended recording-rule naming convention:

```text
<application>:red_request_rate:rate5m
<application>:red_error_rate:ratio5m
<application>:red_duration_seconds:p95_5m
```

Default alert policy for template workloads:

- error ratio > 5% for 10 minutes, gated by non-trivial request traffic;
- p95 request duration > 2 seconds for 10 minutes, gated by non-trivial request traffic.

The traffic gate prevents low-volume or idle services from generating noisy ratio/latency alerts from isolated requests.

## USE

USE is derived primarily from kubelet/cAdvisor, kube-state-metrics, and node-exporter signals.

| Signal | Default measurement | Typical action |
| --- | --- | --- |
| Utilization | CPU usage / requested CPU; memory working set / memory limit | detect exhausted resource headroom |
| Saturation | CPU CFS throttled periods / total CFS periods | detect scheduling pressure before hard failure |
| Errors | container restarts and runtime-specific failure metrics | detect unstable processes/resources |

Recommended recording-rule naming convention:

```text
<application>:use_cpu_utilization:ratio5m
<application>:use_memory_utilization:ratio
<application>:use_cpu_saturation:ratio5m
<application>:use_container_restarts:increase15m
```

Default alert policy for template workloads:

- CPU utilization > 90% of requested CPU for 15 minutes;
- memory working set > 90% of configured memory limits for 10 minutes;
- CPU throttling > 25% for 10 minutes;
- one or more container restarts in a 15-minute window.

Applications with runtime-specific telemetry should add resource signals where they materially improve diagnosis, for example JVM heap utilization.

## Ownership model

The platform owns shared collection, storage, visualization, and common telemetry sources:

- Prometheus / Alertmanager / Grafana;
- Loki;
- Tempo;
- OpenTelemetry Collector;
- kube-state-metrics and node-exporter;
- Traefik request telemetry.

Applications own the semantic interpretation of those signals:

- workload recording rules;
- workload alert thresholds;
- workload Grafana dashboards;
- application-specific runtime metrics;
- SLO and error-budget policy when defined.

This keeps reusable telemetry infrastructure under `platform/services/observability` while application-specific observability remains under `apps/<application>`.

## Dashboard convention

Application SRE dashboards should group panels by strategy instead of presenting an undifferentiated metric catalog:

1. availability/status;
2. RED: request rate, error ratio, p95 duration;
3. USE: CPU utilization, memory utilization, CPU saturation, restart/error signals;
4. runtime-specific resource signals;
5. logs and trace links for diagnosis.

Dependency-Track under `apps/dependency-track` is the reference implementation for this convention.
