# SPDX-License-Identifier: Apache-2.0

# ── Kubernetes Operator Tooling ───────────────────────────────────────────────────────────────────

K8S_NETSHOOT_IMAGE ?= nicolaka/netshoot:v0.16
K8S_STERN_IMAGE ?= ghcr.io/stern/stern:v1.34.0
K8S_POPEYE_IMAGE ?= derailed/popeye:v0.22.1
K8S_K9S_IMAGE ?= derailed/k9s:v0.51.0

K8S_CONTAINER_KUBECONFIG ?= /workspace/$(K8S_KUBECONFIG)
K8S_CLI_CONTAINER_ARGS := --rm --network host --volume "$(CURDIR):/workspace:ro" --workdir /workspace --env KUBECONFIG="$(K8S_CONTAINER_KUBECONFIG)"
K8S_STERN_ALIAS := docker run $(K8S_CLI_CONTAINER_ARGS) "$(K8S_STERN_IMAGE)"
K8S_POPEYE_ALIAS := docker run $(K8S_CLI_CONTAINER_ARGS) "$(K8S_POPEYE_IMAGE)"
K8S_K9S_ALIAS := docker run --interactive --tty $(K8S_CLI_CONTAINER_ARGS) --env TERM=xterm-256color "$(K8S_K9S_IMAGE)"

K8S_DIAGNOSTIC_IMAGE ?= $(K8S_NETSHOOT_IMAGE)
K8S_STERN_ARGS ?=
K8S_POPEYE_ARGS ?=
K8S_K9S_ARGS ?=
K8S_K9S_READONLY ?= true
K8S_K9S_READONLY_FLAG = $(if $(filter true,$(K8S_K9S_READONLY)),--readonly,)

## Follow all workload Pod/container logs with the containerized Stern CLI
k8s-logs-follow: k8s-require-resource
	@$(K8S_STERN_ALIAS) \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--tail "$(K8S_LOG_TAIL)" \
		--timestamps=short $(K8S_STERN_ARGS)
.PHONY: k8s-logs-follow

## Scan live Kubernetes resources for operational issues with the containerized Popeye CLI
k8s-health-scan:
	@$(K8S_POPEYE_ALIAS) \
		-n "$(K8S_OPERATIONS_NAMESPACE)" \
		--logs none $(K8S_POPEYE_ARGS)
.PHONY: k8s-health-scan

## Open the containerized K9s operator console in read-only mode by default
k8s-console:
	@$(K8S_K9S_ALIAS) \
		-n "$(K8S_OPERATIONS_NAMESPACE)" \
		$(K8S_K9S_READONLY_FLAG) $(K8S_K9S_ARGS)
.PHONY: k8s-console
