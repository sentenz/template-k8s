# Platform Configurations

Shared configuration consumed by platform controllers or services belongs here when it has a lifecycle distinct from the capability installation itself.

Examples include cert-manager `ClusterIssuer` resources, Traefik middleware or TLS options, external-secret stores, shared policy resources, PostgreSQL tenant bootstrap configuration, and other controller-specific or service-specific resources.

For the disposable development PostgreSQL service, application-specific databases and roles belong under `platform/configs/postgresql-tenants/dev/` rather than in the PostgreSQL Helm values. This keeps the PostgreSQL runtime configuration consumer-neutral while allowing `clusters/dev` to compose the tenant bootstrap required by development applications.

Create a subdirectory only when the repository contains actual shared configuration for that capability. Environment selection and final composition remain under `clusters/`.
