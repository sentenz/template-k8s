# SPDX-License-Identifier: Apache-2.0

# ── Kubernetes Service Operations ─────────────────────────────────────────────────────────────────

K8S_SERVICE ?= dependency-track
K8S_RESOURCE_KIND ?= deployment
K8S_RESOURCE_NAME ?=
K8S_CONTAINER ?=
K8S_IMAGE ?=
K8S_LOG_TAIL ?= 200
K8S_ROLLOUT_TIMEOUT ?= 5m
K8S_ROLLBACK_REVISION ?=
K8S_AUTO_ROLLBACK ?= true
K8S_OPERATIONS_NAMESPACE ?= $(if $(filter default,$(K8S_NAMESPACE)),$(K8S_SERVICE),$(K8S_NAMESPACE))
ifndef K8S_BACKUP_TIMESTAMP
K8S_BACKUP_TIMESTAMP := $(shell date -u +%Y%m%dT%H%M%SZ)
endif
K8S_BACKUP_DIR ?= logs/kubernetes/backups/$(K8S_ENV)/$(K8S_SERVICE)
K8S_BACKUP_FILE ?= $(K8S_BACKUP_DIR)/$(K8S_BACKUP_TIMESTAMP).yaml
K8S_RECOVERY_FILE ?=

# Validate that a Kubernetes environment was specified
k8s-require-env:
	@if [[ -z "$(strip $(K8S_ENV))" ]]; then \
		echo "error: K8S_ENV is required" >&2; \
		echo "usage: make <target> K8S_ENV=<dev|stage|prod>" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-env

# Validate that a workload resource was specified
k8s-require-resource:
	@if [[ -z "$(strip $(K8S_RESOURCE_NAME))" ]]; then \
		echo "error: K8S_RESOURCE_NAME is required" >&2; \
		echo "usage: make <target> K8S_RESOURCE_NAME=<name> [K8S_RESOURCE_KIND=deployment]" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-resource

# Validate parameters required for an image upgrade
k8s-require-upgrade: k8s-require-env k8s-require-resource
	@if [[ -z "$(strip $(K8S_CONTAINER))" ]]; then \
		echo "error: K8S_CONTAINER is required" >&2; \
		exit 2; \
	fi

	@if [[ -z "$(strip $(K8S_IMAGE))" ]]; then \
		echo "error: K8S_IMAGE is required" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-upgrade

## Monitor Kubernetes service health, workload state, resource usage, and warning events
k8s-monitor: k8s-require-resource
	@echo "──── Workload ────────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-o wide

	@echo "──── Pods, Services & Ingresses ──────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get \
		pods,services,ingresses \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-o wide

	@echo "──── Resource Usage ──────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl top pods \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		|| echo "Metrics API unavailable; skipping resource usage."

	@echo "──── Warning Events ──────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl get events \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--field-selector type=Warning \
		--sort-by=.lastTimestamp
.PHONY: k8s-monitor

## Continuously watch Kubernetes pods for service availability and rollout changes
k8s-watch:
	@$(K8S_TOOLS_ALIAS) kubectl get pods \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--watch
.PHONY: k8s-watch

## Describe a Kubernetes workload and display its rollout revision history
k8s-describe: k8s-require-resource
	@echo "──── Workload Description ────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl describe \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@echo "──── Rollout History ─────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl rollout history \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-describe

## Retrieve recent logs from all containers associated with a Kubernetes workload
k8s-logs: k8s-require-resource
	@$(K8S_TOOLS_ALIAS) kubectl logs \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--all-containers=true \
		--all-pods=true \
		--prefix=true \
		--tail="$(K8S_LOG_TAIL)"
.PHONY: k8s-logs

## Troubleshoot a Kubernetes service using health, events, workload details, rollout history, and logs
k8s-troubleshoot: k8s-require-resource
	@$(MAKE) -s k8s-monitor
	@$(MAKE) -s k8s-describe
	@echo "──── Recent Logs ─────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-logs || echo "Logs unavailable for the selected workload."
.PHONY: k8s-troubleshoot

## Create a recovery-ready snapshot of the rendered Kubernetes desired state
k8s-backup: k8s-require-env
	@overlay_dir="manifests/overlays/$(K8S_ENV)/$(K8S_SERVICE)"
	@if [[ ! -f "$$overlay_dir/kustomization.yaml" ]]; then \
		echo "error: Kubernetes overlay does not exist: $$overlay_dir" >&2; \
		exit 2; \
	fi

	@umask 077
	@mkdir -p "$(K8S_BACKUP_DIR)"
	@tmp_file="$$(mktemp "$(K8S_BACKUP_DIR)/.snapshot.XXXXXX")"
	@trap 'rm -f "$$tmp_file"' EXIT

	@$(K8S_TOOLS_ALIAS) kustomize build \
		"$$overlay_dir" \
		--enable-helm \
		--load-restrictor=LoadRestrictionsNone \
		> "$$tmp_file"

	@chmod 0600 "$$tmp_file"
	@mv "$$tmp_file" "$(K8S_BACKUP_FILE)"
	@trap - EXIT
	@echo "Kubernetes recovery snapshot: $(K8S_BACKUP_FILE)"
.PHONY: k8s-backup

## Recover Kubernetes resources from a previously rendered recovery snapshot
k8s-recover: k8s-require-env
	@if [[ -z "$(strip $(K8S_RECOVERY_FILE))" ]]; then \
		echo "error: K8S_RECOVERY_FILE is required" >&2; \
		echo "usage: make k8s-recover K8S_ENV=<env> K8S_RECOVERY_FILE=<file>" >&2; \
		exit 2; \
	fi

	@if [[ ! -f "$(K8S_RECOVERY_FILE)" ]]; then \
		echo "error: recovery file does not exist: $(K8S_RECOVERY_FILE)" >&2; \
		exit 2; \
	fi

	@$(MAKE) -s k8s-confirm K8S_STACK_DIR="$(K8S_SERVICE)"

	@$(K8S_TOOLS_ALIAS) kubectl apply \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		-f "$(K8S_RECOVERY_FILE)"

	@if [[ -n "$(strip $(K8S_RESOURCE_NAME))" ]]; then \
		$(K8S_TOOLS_ALIAS) kubectl rollout status \
			"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
			--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
			--kubeconfig "$(K8S_KUBECONFIG)" \
			--timeout="$(K8S_ROLLOUT_TIMEOUT)"; \
	fi
.PHONY: k8s-recover

## Upgrade a Kubernetes workload image with pre-change backup, rollout verification, and automatic rollback
k8s-upgrade: k8s-require-upgrade k8s-backup
	@echo "──── Current Rollout History ─────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl rollout history \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@$(MAKE) -s k8s-confirm K8S_STACK_DIR="$(K8S_SERVICE)"

	@echo "──── Upgrade ─────────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl set image \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		"$(K8S_CONTAINER)=$(K8S_IMAGE)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@if ! $(K8S_TOOLS_ALIAS) kubectl rollout status \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--timeout="$(K8S_ROLLOUT_TIMEOUT)"; then \
		echo "Upgrade rollout failed."; \
		if [[ "$(K8S_AUTO_ROLLBACK)" == "true" ]]; then \
			echo "Automatic rollback initiated."; \
			$(K8S_TOOLS_ALIAS) kubectl rollout undo \
				"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
				--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
				--kubeconfig "$(K8S_KUBECONFIG)"; \
			$(K8S_TOOLS_ALIAS) kubectl rollout status \
				"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
				--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
				--kubeconfig "$(K8S_KUBECONFIG)" \
				--timeout="$(K8S_ROLLOUT_TIMEOUT)"; \
		fi; \
		exit 1; \
	fi

	@echo "Upgrade completed successfully."
.PHONY: k8s-upgrade

## Roll back a Kubernetes workload to its previous or explicitly selected revision
k8s-rollback: k8s-require-env k8s-require-resource
	@echo "──── Rollout History ─────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl rollout history \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@$(MAKE) -s k8s-confirm K8S_STACK_DIR="$(K8S_SERVICE)"

	@if [[ -n "$(strip $(K8S_ROLLBACK_REVISION))" ]]; then \
		$(K8S_TOOLS_ALIAS) kubectl rollout undo \
			"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
			--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
			--kubeconfig "$(K8S_KUBECONFIG)" \
			--to-revision="$(K8S_ROLLBACK_REVISION)"; \
	else \
		$(K8S_TOOLS_ALIAS) kubectl rollout undo \
			"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
			--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
			--kubeconfig "$(K8S_KUBECONFIG)"; \
	fi

	@$(K8S_TOOLS_ALIAS) kubectl rollout status \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--timeout="$(K8S_ROLLOUT_TIMEOUT)"
.PHONY: k8s-rollback
