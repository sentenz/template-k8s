# PostgreSQL

PostgreSQL is modeled as a platform-managed runtime service for the example stack and therefore lives under `platform/services/`.

The base owns the namespace. Each environment overlay owns its Helm release and values. Development uses disposable cluster-local fixture credentials; stage and production expect credentials to be supplied externally.

## Development tenancy

Development keeps one shared PostgreSQL instance and gives each application tenant its own database, login role, and namespace-local Secret.

Dependency-Track is the first tenant:

| Application namespace | Database | Login role | Application Secret |
| --- | --- | --- | --- |
| `dependency-track` | `dtrack` | `dtrack` | `dependency-track-database` |

The dev cluster generates the PostgreSQL-side and application-side Secrets from the same fixture file. Dependency-Track consumes only its namespace-local Secret.

The Bitnami chart's native `primary.initdb.scripts` creates the tenant role/database on first PostgreSQL initialization. Because the Kind environment is disposable, tenant changes should recreate the PostgreSQL data or the development cluster. Do not use this first-boot mechanism for persistent environments.

The chart's native NetworkPolicy is configured with `allowExternal: false`; only namespaces labeled `platform.sentenz.io/postgresql-client: "true"` may connect to PostgreSQL. Application roles must not receive `SUPERUSER`, `CREATEDB`, `CREATEROLE`, `REPLICATION`, or `BYPASSRLS`.

To add another development tenant, add a fixture, generate one Secret in the PostgreSQL namespace and one in the application namespace, extend the init script, and label the application namespace as a PostgreSQL client. No per-tenant Job or NetworkPolicy manifest is required.

Stage and production keep externally managed Secrets. When persistent environments require independent backup/restore, high availability, or stronger isolation, prefer dedicated PostgreSQL clusters or a PostgreSQL operator rather than extending the dev bootstrap pattern.
