# Traefik

Traefik is a cluster networking controller and therefore lives under `platform/controllers/`.

The base owns the namespace. Environment overlays own chart references and networking values. Development changes the Service to fixed NodePorts for the local Kind workflow. Stage and production use a LoadBalancer Service and explicitly disable host networking.
