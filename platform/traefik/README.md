# Traefik

Traefik provides ingress for the example stack.

The base owns the namespace. Environment overlays own the Helm release and Kubernetes-level networking differences. Development changes the Service to fixed NodePorts for the local Kind workflow. Stage and production use a LoadBalancer Service and explicitly disable host networking.
