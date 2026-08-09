# Dependency-Track RDS patches

These shared patches adapt the base Dependency-Track manifests for non-development environments where PostgreSQL is externally managed, such as AWS RDS.

## Runtime architecture

- PostgreSQL runs outside the Kubernetes manifests; the in-cluster PostgreSQL base is not part of the stage or production runtime.
- The chart-managed `dependency-track-db` and `dependency-track-kek` Secrets are removed from the final rendered manifests.
- The API server reads `DT_DATASOURCE_URL` from the externally managed `dependency-track-db` Secret.
- Existing chart secret mounts continue to provide the database username, password, and database KEK from externally managed Secrets with the same names and keys.
- The frontend API base URL is cleared so browser requests use same-host relative routing through the rendered Ingress.

## Secret contract

Provision the required Secrets in the `dependency-track` namespace before deploying an overlay that consumes these patches.

- `dependency-track-db`
  - `jdbcUrl`: complete JDBC URL for the external PostgreSQL database, for example `jdbc:postgresql://<rds-endpoint>:5432/dtrack?sslmode=require`
  - `username`: database username
  - `password`: database password
- `dependency-track-kek`
  - `kek`: Dependency-Track database KEK value; the application value is a Base64-encoded 32-byte key

Use an external secret-management mechanism such as External Secrets Operator, Sealed Secrets, SOPS-based deployment automation, or another platform-appropriate secret store. Do not commit environment credentials or KEK material to this repository.

The following manifest shows the required key structure only:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: dependency-track-db
  namespace: dependency-track
type: Opaque
stringData:
  jdbcUrl: "jdbc:postgresql://<rds-endpoint>:5432/dtrack?sslmode=require"
  username: "<username>"
  password: "<password>"
---
apiVersion: v1
kind: Secret
metadata:
  name: dependency-track-kek
  namespace: dependency-track
type: Opaque
stringData:
  kek: "<base64-encoded-32-byte-kek>"
```

> [!NOTE]
> `stringData` accepts the Dependency-Track KEK application value directly. If a Secret is authored with Kubernetes `data` instead, each value must additionally be Base64-encoded for Kubernetes Secret serialization.

## Patch behavior

- `delete-chart-db-secret.yaml`
  > Removes the development chart-managed `dependency-track-db` Secret from the rendered manifests.

- `delete-chart-kek-secret.yaml`
  > Removes the development chart-managed `dependency-track-kek` Secret from the rendered manifests.

- `patch-api-server-external-database.yaml`
  > Replaces `DT_DATASOURCE_URL` with a reference to `dependency-track-db.jdbcUrl` while preserving the chart's existing database credential mounts.

- `patch-frontend-relative-api.yaml`
  > Clears `API_BASE_URL` so the frontend uses same-host relative API routing instead of the development `dependency-track.localhost` URL.

## Operations

These patches configure the Kubernetes application boundary only. Database snapshots, point-in-time recovery, failover, maintenance, storage lifecycle, parameter management, and other RDS operations remain responsibilities of the external PostgreSQL platform.

Use the root [Troubleshoot](../../../README.md#3-troubleshoot) runbook to validate the Kubernetes workload and the application-to-database DNS/TCP path. For stage or production, provide the external database endpoint explicitly:

```bash
make k8s-database-diagnose K8S_ENV=<stage|prod> K8S_DATABASE_HOST=<rds-endpoint>
```
