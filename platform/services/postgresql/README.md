# PostgreSQL

PostgreSQL is modeled as a platform-managed runtime service for the example stack and therefore lives under `platform/services/`.

The base owns the namespace. Each environment overlay owns its Helm release and values. Development generates a disposable `postgresql-auth` Secret; stage and production expect that Secret to be supplied externally in the `postgresql` namespace with keys `postgres-password` and `password`.

In a product-specific repository where a PostgreSQL instance is exclusively owned by one application and shares its lifecycle, colocating that database deployment with the application can be more appropriate. This template keeps PostgreSQL under `platform/services/` to demonstrate the platform-service boundary requested by the repository architecture.
