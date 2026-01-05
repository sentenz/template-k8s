# Changelog

# 1.0.0 (2026-01-05)


### Bug Fixes

* create an Ingress object for Traefik to patch Dependency Track API and Frontend on separate hostnames ([d4e49d2](https://github.com/sentenz/template-k8s/commit/d4e49d2ec8695eacc67365d21c20330c54edec95))


### Features

* enable external Load Balancer using `servicelb` within k3s ([8549ecb](https://github.com/sentenz/template-k8s/commit/8549ecb47ea64aaf516ac4fb60ad69fe8c0177e2))
* expose applications in K3s with `ClusterIP` with Traefik instead of `NodePort` ([5229b3e](https://github.com/sentenz/template-k8s/commit/5229b3e6ce8d6394ef782f9c1875254b14085f66))
