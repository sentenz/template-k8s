# Traefik

Traefik is a cluster networking controller and therefore lives under `platform/controllers/`.

The base owns the namespace. Environment overlays own chart references and networking values. All environments use a LoadBalancer Service and explicitly disable host networking. Development also assigns fixed NodePorts for the local Kind port mappings.
