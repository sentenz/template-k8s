# Dependency-Track external PostgreSQL runtime

These patches adapt the shared Dependency-Track Helm rendering for non-development environments where PostgreSQL is supplied externally, such as AWS RDS.

The final manifests intentionally remove the chart-managed `dependency-track-db` and `dependency-track-kek` Secrets. Provision both Secrets in the `dependency-track` namespace before deployment:

- `dependency-track-db`
  - `jdbcUrl`: complete JDBC URL for the external PostgreSQL database, for example `jdbc:postgresql://<rds-endpoint>:5432/dtrack?sslmode=require`
  - `username`: database username
  - `password`: database password
- `dependency-track-kek`
  - `kek`: base64-encoded 32-byte Dependency-Track database KEK

The API server reads `DT_DATASOURCE_URL` from the `jdbcUrl` Secret key, while the chart's existing secret volumes continue to mount the database credentials and KEK. The frontend API base URL is cleared so browser requests use the same host as the rendered Ingress.

The external Secrets are operational prerequisites and must be managed outside this repository, for example through External Secrets Operator, Sealed Secrets, SOPS-based deployment automation, or another cluster secret-management mechanism.
