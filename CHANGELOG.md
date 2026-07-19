# Changelog

## [2.0.0](https://github.com/sentenz/template-k8s/compare/1.0.0...2.0.0) (2026-07-19)

### ⚠ BREAKING CHANGES

* **local development:** replace the Docker Compose-managed K3s environment with a reproducible three-node Kind cluster. The `examples/docker-compose.yaml` file and the `examples/config/` directory were removed. `make k8s-setup` now creates the cluster with `config/kind-config.yaml` and writes its generated kubeconfig to `config/kubeconfig.yaml`. Scripts, IDE settings, and automation that reference `examples/config/kubeconfig.yaml` must use the new path, and existing K3s development clusters must be removed and recreated with Kind.

### Code Refactoring

* **local development:** migrate local Kubernetes development from K3s to Kind ([d88deb7](https://github.com/sentenz/template-k8s/commit/d88deb72dc9b49e4be69466958e11fdbb73e93f4))

### Migration

1. From a `1.0.0` checkout, run `make k8s-teardown` to remove the previous K3s/Docker Compose environment.
2. Update the repository and run `make bootstrap` to install the pinned Kind CLI when required.
3. Run `make k8s-setup` to create the Kind cluster and generate `config/kubeconfig.yaml`.
4. Replace references to `examples/config/kubeconfig.yaml` with `config/kubeconfig.yaml` in local scripts and tool configuration.

# 1.0.0 (2026-01-05)


### Bug Fixes

* create an Ingress object for Traefik to patch Dependency Track API and Frontend on separate hostnames ([d4e49d2](https://github.com/sentenz/template-k8s/commit/d4e49d2ec8695eacc67365d21c20330c54edec95))


### Features

* enable external Load Balancer using `servicelb` within k3s ([8549ecb](https://github.com/sentenz/template-k8s/commit/8549ecb47ea64aaf516ac4fb60ad69fe8c0177e2))
* expose applications in K3s with `ClusterIP` with Traefik instead of `NodePort` ([5229b3e](https://github.com/sentenz/template-k8s/commit/5229b3e6ce8d6394ef782f9c1875254b14085f66))
