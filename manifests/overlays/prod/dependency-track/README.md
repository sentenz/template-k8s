# Production overlay notes

This overlay renders Dependency-Track for a production cluster with externally managed PostgreSQL.

## Runtime architecture

- PostgreSQL is external, such as AWS RDS; the in-cluster PostgreSQL base is intentionally omitted.
- The shared RDS patches remove the development chart-managed database and KEK Secrets.
- Provision `dependency-track-db` and `dependency-track-kek` in the `dependency-track` namespace before deployment. See `manifests/patches/dependency-track-rds/README.md` for the required keys.
- The frontend uses same-host relative API routing rather than the development `dependency-track.localhost` URL.

## Ingress

The template Ingress hostname is `dependency-track.example.com`. Replace it with the production DNS name and configure the appropriate production TLS integration before deployment.

Database snapshots, point-in-time recovery, failover, maintenance, and storage lifecycle remain responsibilities of the external PostgreSQL platform rather than these Kubernetes manifests.
