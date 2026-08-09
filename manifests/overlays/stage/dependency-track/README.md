# Stage overlay notes for AWS EKS

This overlay adapts the base manifests for a remote staging cluster on EKS.

## Runtime architecture

- PostgreSQL is external and supplied by AWS RDS; the in-cluster PostgreSQL base is intentionally omitted.
- The shared RDS patches remove the development chart-managed database and KEK Secrets.
- Provision `dependency-track-db` and `dependency-track-kek` in the `dependency-track` namespace before deployment. See `manifests/patches/dependency-track-rds/README.md` for the required keys.
- The frontend uses same-host relative API routing rather than the development `dependency-track.localhost` URL.

## Traefik

- The Traefik Service is patched to `type: LoadBalancer` so EKS can provision a cloud load balancer for ports 80/443.
- `hostNetwork` is disabled for the remote cluster.
- The Dependency-Track Ingress uses `dependency-track.staging.example.com`; replace this template hostname with the staging DNS name before deployment.

## TLS and certificates

Do not use the development overlay's self-signed `secretGenerator` in staging. Use cert-manager, an existing Kubernetes TLS Secret, or load-balancer certificate integration suitable for the cluster.

## Access

After applying the overlay, inspect the Traefik load-balancer address:

```sh
kubectl -n traefik get svc traefik
```

Point staging DNS at the returned external address and configure TLS for the selected hostname.
