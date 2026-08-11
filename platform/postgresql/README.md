# PostgreSQL

PostgreSQL is a platform dependency for the Dependency-Track example workload.

The base owns the namespace. Each environment overlay owns its Helm release and values. Development generates a disposable `postgresql-auth` Secret; stage and production expect that Secret to be supplied externally in the `postgresql` namespace with keys `postgres-password` and `password`.
