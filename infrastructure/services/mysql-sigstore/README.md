# MySQL (Sigstore)

MySQL is modeled as an infrastructure-managed runtime service for the self-hosted Sigstore stack and therefore lives under `infrastructure/services/`.

The Sigstore charts (Fulcio, Rekor, and the Trillian transparency-log backend) are MySQL-only: Trillian's `--storage_system`/`--mysql_uri` arguments and Rekor's `--search_index.*` arguments only wire MySQL DSNs. This dedicated instance is therefore MySQL rather than the shared PostgreSQL used by Dependency-Track.

The base owns the namespace. Each environment overlay owns its Helm release and values. Development generates a disposable `mysql-sigstore-auth` Secret; stage and production expect that Secret to be supplied externally in the `mysql-sigstore` namespace with keys `mysql-root-password` and `mysql-password`.

The instance creates a single `trillian` database and a `sigstore` user. The Sigstore service bridges these credentials into the `sigstore-mysql` Secret (keys `mysql-user`, `mysql-password`, `mysql-database`) that the Fulcio and Rekor charts consume via `mysql.auth.existingSecret`.
