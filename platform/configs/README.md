# Platform Configurations

Shared configuration consumed by platform controllers or services belongs here when it has a lifecycle distinct from the capability installation itself.

Examples include cert-manager `ClusterIssuer` resources, Traefik middleware or TLS options, external-secret stores, shared policy resources, and other controller-specific custom resources.

Create a subdirectory only when the repository contains actual shared configuration for that capability. Environment selection and final composition remain under `clusters/`.
