# SPDX-License-Identifier: Apache-2.0

# ── Kubernetes Service Diagnostics ────────────────────────────────────────────────────────────────

K8S_POD ?=
K8S_NODE ?=
K8S_SERVICE_NAME ?=
K8S_SERVICE_ACCOUNT ?=
K8S_DEBUG_IMAGE ?= $(K8S_NETSHOOT_IMAGE)
K8S_DEBUG_TARGET ?=
K8S_SMOKE_TEST_URL ?=
K8S_SMOKE_TEST_TIMEOUT ?= 10
K8S_DATABASE_HOST ?=
K8S_DATABASE_PORT ?= 5432
K8S_POSTGRES_NAMESPACE ?= postgresql
K8S_TOOLS_STDIN_ALIAS := docker run --rm --interactive --network host --volume "$(CURDIR):/workspace" --workdir /workspace "$(K8S_TOOLS_IMAGE)"
K8S_TOOLS_INTERACTIVE_ALIAS := docker run --rm --interactive --tty --network host --volume "$(CURDIR):/workspace" --workdir /workspace "$(K8S_TOOLS_IMAGE)"
K8S_DIAGNOSTIC_RUN = $(K8S_TOOLS_ALIAS) kubectl run
K8S_DIAGNOSTIC_RUN_FLAGS = --namespace "$(K8S_OPERATIONS_NAMESPACE)" --kubeconfig "$(K8S_KUBECONFIG)" --image="$(K8S_DIAGNOSTIC_IMAGE)" --restart=Never --attach=true --rm --command --

# Validate that a Kubernetes Pod was specified for drill-down diagnostics
k8s-require-pod:
	@if [[ -z "$(strip $(K8S_POD))" ]]; then \
		echo "error: K8S_POD is required" >&2; \
		echo "usage: make <target> K8S_POD=<pod>" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-pod

# Validate that a Kubernetes Node was specified for drill-down diagnostics
k8s-require-node:
	@if [[ -z "$(strip $(K8S_NODE))" ]]; then \
		echo "error: K8S_NODE is required" >&2; \
		echo "usage: make k8s-node-diagnose K8S_NODE=<node>" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-node

# Validate parameters required for an application smoke test
k8s-require-smoke-test:
	@if [[ -z "$(strip $(K8S_SMOKE_TEST_URL))" ]]; then \
		echo "error: K8S_SMOKE_TEST_URL is required" >&2; \
		echo "usage: make k8s-smoke-test K8S_SMOKE_TEST_URL=<url>" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-smoke-test

## Verify Kubernetes API connectivity, control-plane readiness, versions, and node visibility
k8s-preflight:
	@echo "──── Kubernetes Version ──────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl version --kubeconfig "$(K8S_KUBECONFIG)"

	@echo "──── Cluster Information ─────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl cluster-info --kubeconfig "$(K8S_KUBECONFIG)"

	@echo "──── API Readiness ────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get --raw='/readyz?verbose' --kubeconfig "$(K8S_KUBECONFIG)" \
		|| echo "Kubernetes API readiness endpoint unavailable to the current identity."

	@echo "──── Nodes ────────────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get nodes --kubeconfig "$(K8S_KUBECONFIG)" -o wide
.PHONY: k8s-preflight

## Diagnose one Kubernetes Pod's readiness, restart counts, container states, scheduling, probes, and events
k8s-pod-diagnose: k8s-require-pod
	@echo "──── Pod State ────────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get "pod/$(K8S_POD)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,WAITING:.status.containerStatuses[*].state.waiting.reason,PREVIOUS:.status.containerStatuses[*].lastState.terminated.reason,NODE:.spec.nodeName'

	@echo "──── Pod Description ─────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl describe "pod/$(K8S_POD)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-pod-diagnose

## Diagnose one Kubernetes Node's readiness, pressure conditions, taints, capacity, and workloads
k8s-node-diagnose: k8s-require-node
	@echo "──── Node State ──────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get "node/$(K8S_NODE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY-PRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,DISK-PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status,PID-PRESSURE:.status.conditions[?(@.type=="PIDPressure")].status,VERSION:.status.nodeInfo.kubeletVersion'

	@echo "──── Selected Node Resource Usage ────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl top "node/$(K8S_NODE)" --kubeconfig "$(K8S_KUBECONFIG)" \
		|| echo "Metrics API unavailable; skipping node resource usage."

	@echo "──── Node Description ────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl describe "node/$(K8S_NODE)" --kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-node-diagnose

## Diagnose Service selectors, EndpointSlices, ingress routing, and NetworkPolicies
k8s-network-diagnose:
	@echo "──── Network Resources ───────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get \
		services,endpointslices,ingresses,networkpolicies \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-o wide

	@if [[ -n "$(strip $(K8S_SERVICE_NAME))" ]]; then \
		echo "──── Selected Service ────────────────────────────────────────────────────────────────────"; \
		$(K8S_TOOLS_ALIAS) kubectl describe "service/$(K8S_SERVICE_NAME)" \
			--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
			--kubeconfig "$(K8S_KUBECONFIG)"; \
		echo "──── Selected Service EndpointSlices ─────────────────────────────────────────────────────"; \
		$(K8S_TOOLS_ALIAS) kubectl get endpointslices \
			--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
			--kubeconfig "$(K8S_KUBECONFIG)" \
			--selector "kubernetes.io/service-name=$(K8S_SERVICE_NAME)" \
			-o wide; \
	fi
.PHONY: k8s-network-diagnose

## Diagnose effective Kubernetes RBAC permissions for the current identity or a ServiceAccount
k8s-auth-diagnose:
	@set -euo pipefail; \
	identity_args=(); \
	if [[ -n "$(strip $(K8S_SERVICE_ACCOUNT))" ]]; then \
		identity_args+=("--as=system:serviceaccount:$(K8S_OPERATIONS_NAMESPACE):$(K8S_SERVICE_ACCOUNT)"); \
	fi; \
	echo "──── Kubernetes Identity ─────────────────────────────────────────────────────────────────"; \
	$(K8S_TOOLS_ALIAS) kubectl auth whoami \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		"$${identity_args[@]}" || true; \
	echo "──── Effective Namespace Permissions ────────────────────────────────────────────────────"; \
	$(K8S_TOOLS_ALIAS) kubectl auth can-i --list \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		"$${identity_args[@]}"
.PHONY: k8s-auth-diagnose

## Diagnose Kubernetes-managed PostgreSQL storage in dev; stage and prod use AWS RDS
k8s-storage-diagnose: k8s-require-env
	@if [[ "$(K8S_ENV)" != "dev" ]]; then \
		echo "Kubernetes PostgreSQL storage diagnostics skipped: $(K8S_ENV) uses AWS RDS."; \
		exit 0; \
	fi

	@echo "──── PostgreSQL Workload & Persistent Storage ────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get \
		statefulsets,pods,services,persistentvolumeclaims \
		--namespace "$(K8S_POSTGRES_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-o wide

	@echo "──── Storage Classes & Persistent Volumes ────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get storageclasses,persistentvolumes \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@echo "──── PostgreSQL Storage Warning Events ───────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get events \
		--namespace "$(K8S_POSTGRES_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--field-selector type=Warning \
		--sort-by=.lastTimestamp
.PHONY: k8s-storage-diagnose

## Validate application-to-database DNS and TCP connectivity; dev uses Kubernetes PostgreSQL and stage/prod use AWS RDS
k8s-database-diagnose: k8s-require-env
	@set -euo pipefail; \
	db_host="$(strip $(K8S_DATABASE_HOST))"; \
	if [[ "$(K8S_ENV)" == "dev" ]]; then \
		$(MAKE) -s k8s-storage-diagnose; \
		if [[ -z "$$db_host" ]]; then \
			db_host="postgresql.$(K8S_POSTGRES_NAMESPACE).svc.cluster.local"; \
		fi; \
	elif [[ -z "$$db_host" ]]; then \
		echo "error: K8S_DATABASE_HOST is required for $(K8S_ENV) because the database is external AWS RDS" >&2; \
		echo "usage: make k8s-database-diagnose K8S_ENV=$(K8S_ENV) K8S_DATABASE_HOST=<rds-endpoint>" >&2; \
		exit 2; \
	fi; \
	echo "Testing database connectivity from namespace '$(K8S_OPERATIONS_NAMESPACE)' to $$db_host:$(K8S_DATABASE_PORT)"; \
	pod_name="k8s-db-diagnose-$$(date +%s)-$${RANDOM}"; \
	$(K8S_DIAGNOSTIC_RUN) "$$pod_name" $(K8S_DIAGNOSTIC_RUN_FLAGS) \
		sh -ec 'nslookup "$$1"; timeout 5 nc "$$1" "$$2" </dev/null >/dev/null' _ "$$db_host" "$(K8S_DATABASE_PORT)"
.PHONY: k8s-database-diagnose

## Compare rendered Kustomize/Helm desired state with live Kubernetes resources
k8s-diff: k8s-require-overlay
	@$(K8S_KUSTOMIZE_BUILD) \
		| $(K8S_TOOLS_STDIN_ALIAS) kubectl diff \
			--kubeconfig "$(K8S_KUBECONFIG)" \
			-f -
.PHONY: k8s-diff

## Run an application-level HTTP(S) smoke test from inside the Kubernetes service namespace
k8s-smoke-test: k8s-require-smoke-test
	@set -euo pipefail; \
	pod_name="k8s-smoke-$$(date +%s)-$${RANDOM}"; \
	$(K8S_DIAGNOSTIC_RUN) "$$pod_name" $(K8S_DIAGNOSTIC_RUN_FLAGS) \
		curl --fail --show-error --silent --max-time "$(K8S_SMOKE_TEST_TIMEOUT)" --output /dev/null "$(K8S_SMOKE_TEST_URL)"
.PHONY: k8s-smoke-test

## Launch an interactive Netshoot ephemeral debug container in a Kubernetes Pod
k8s-debug: k8s-require-pod
	@$(K8S_TOOLS_INTERACTIVE_ALIAS) kubectl debug \
		"pod/$(K8S_POD)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--image="$(K8S_DEBUG_IMAGE)" $(if $(strip $(K8S_DEBUG_TARGET)),--target="$(K8S_DEBUG_TARGET)",) \
		--interactive \
		--tty
.PHONY: k8s-debug

## Troubleshoot a Kubernetes service using deterministic checks plus a Popeye health scan
k8s-troubleshoot: k8s-require-resource
	@$(MAKE) -s k8s-preflight || echo "Preflight diagnostics reported an issue."
	@$(MAKE) -s k8s-monitor
	@$(MAKE) -s k8s-health-scan || echo "Popeye health scan reported an issue."
	@$(MAKE) -s k8s-describe
	@echo "──── Recent Logs ─────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-logs || echo "Logs unavailable for the selected workload."
	@echo "──── Previous Container Logs ─────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-logs-previous || echo "No previous container logs are available."
	@$(MAKE) -s k8s-network-diagnose || echo "Network diagnostics reported an issue."
	@$(MAKE) -s k8s-auth-diagnose || echo "RBAC diagnostics reported an issue."
.PHONY: k8s-troubleshoot
