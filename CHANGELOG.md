# Changelog

## [2.0.4](https://github.com/sentenz/template-k8s/compare/2.0.3...2.0.4) (2026-07-21)

### Bug Fixes

* resolve Dependency-Track chart v2 deployment values ([#43](https://github.com/sentenz/template-k8s/issues/43)) ([ea1fe33](https://github.com/sentenz/template-k8s/commit/ea1fe33950e6b6edf5104c30791e75d9fa5b0f0d))

## [2.0.3](https://github.com/sentenz/template-k8s/compare/2.0.2...2.0.3) (2026-07-21)

### Bug Fixes

* update dependency-track chart version to 2.0.0-rc.3 in kustomization.yaml ([bcc7919](https://github.com/sentenz/template-k8s/commit/bcc79197948fa2a57516d973fa619c97807c4c90))

## [2.0.2](https://github.com/sentenz/template-k8s/compare/2.0.1...2.0.2) (2026-07-21)

### Bug Fixes

* update ingress resource names to match service names in patch-dependency-track-ingress.yaml ([390b5ab](https://github.com/sentenz/template-k8s/commit/390b5ab33fd8eab1695d662323da262725c541a0))

## [2.0.1](https://github.com/sentenz/template-k8s/compare/2.0.0...2.0.1) (2026-07-21)

### Bug Fixes

* modidy kustomize patch target for dependency-track frontend ([e4982f8](https://github.com/sentenz/template-k8s/commit/e4982f8c2bf6f68de353c04206fee18b7b9a4362))

## [2.0.0](https://github.com/sentenz/template-k8s/compare/1.0.0...2.0.0) (2026-07-19)

### ⚠ BREAKING CHANGES

* local Kubernetes development now uses Kind instead of the Docker Compose-based K3s environment
* the previous K3s Docker Compose definition and the obsolete `examples/config/` paths have been removed
* local cluster configuration now resides in `config/kind-config.yaml`, and the generated kubeconfig is written to `config/kubeconfig.yaml`
* use `make k8s-setup` and `make k8s-teardown` for the local cluster lifecycle

### Code Refactoring

* migrate local Kubernetes development from K3s to Kind ([#36](https://github.com/sentenz/template-k8s/issues/36)) ([d88deb7](https://github.com/sentenz/template-k8s/commit/d88deb72dc9b49e4be69466958e11fdbb73e93f4))

# 1.0.0 (2026-01-05)


### Bug Fixes

* create an Ingress object for Traefik to patch Dependency Track API and Frontend on separate hostnames ([d4e49d2](https://github.com/sentenz/template-k8s/commit/d4e49d2ec8695eacc67365d21c20330c54edec95))


### Features

* enable external Load Balancer using `servicelb` within k3s ([8549ecb](https://github.com/sentenz/template-k8s/commit/8549ecb47ea64aaf516ac4fb60ad69fe8c0177e2))
* expose applications in K3s with `ClusterIP` with Traefik instead of `NodePort` ([5229b3e](https://github.com/sentenz/template-k8s/commit/5229b3e6ce8d6394ef782f9c1875254b14085f66))
