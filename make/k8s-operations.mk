# SPDX-License-Identifier: Apache-2.0

# ── Kubernetes Service Operations ─────────────────────────────────────────────────────────────────

K8S_SERVICE ?= dependency-track
K8S_RESOURCE_KIND ?= deployment
K8S_RESOURCE_NAME ?=
K8S_CONTAINER ?=
K8S_IMAGE ?=
K8S_LOG_TAIL ?= 200
K8S_LOG_PREVIOUS ?= false
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

K8S_LOG_PREVIOUS_FLAG = $(if $(filter true,$(K8S_LOG_PREVIOUS)),--previous=true,)

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

# Validate parameters required for a temporary live image hotfix
k8s-require-image-hotfix: k8s-require-env k8s-require-resource
	@if [[ -z "$(strip $(K8S_CONTAINER))" ]]; then \
		echo "error: K8S_CONTAINER is required" >&2; \
		exit 2; \
	fi

	@if [[ -z "$(strip $(K8S_IMAGE))" ]]; then \
		echo "error: K8S_IMAGE is required" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-image-hotfix

# Validate that the selected Kustomize overlay exists
k8s-require-overlay: k8s-require-env
	@if [[ ! -f "$(call K8S_OVERLAY_DIR,$(K8S_ENV),$(K8S_SERVICE))/kustomization.yaml" ]]; then \
		echo "error: Kubernetes overlay does not exist: $(call K8S_OVERLAY_DIR,$(K8S_ENV),$(K8S_SERVICE))" >&2; \
		exit 2; \
	fi
.PHONY: k8s-require-overlay

# Show rollout history for the selected workload
k8s-rollout-history: k8s-require-resource
	@$(K8S_TOOLS_ALIAS) kubectl rollout history \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-rollout-history

# Wait for the selected workload rollout to complete
k8s-rollout-status: k8s-require-resource
	@$(K8S_TOOLS_ALIAS) kubectl rollout status \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--timeout="$(K8S_ROLLOUT_TIMEOUT)"
.PHONY: k8s-rollout-status

# Roll back the selected workload to the previous or explicitly selected revision
k8s-rollout-undo: k8s-require-resource
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
.PHONY: k8s-rollout-undo

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

## Describe a Kubernetes workload and display its rollout revision history
k8s-describe: k8s-require-resource
	@echo "──── Workload Description ────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl describe \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@echo "──── Rollout History ─────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-rollout-history
.PHONY: k8s-describe

## Retrieve recent logs from all containers associated with a Kubernetes workload
k8s-logs: k8s-require-resource
	@$(K8S_TOOLS_ALIAS) kubectl logs \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)" \
		--all-containers=true \
		--all-pods=true \
		--prefix=true $(K8S_LOG_PREVIOUS_FLAG) \
		--tail="$(K8S_LOG_TAIL)"
.PHONY: k8s-logs

## Retrieve logs from the previous terminated container instances of a Kubernetes workload
k8s-logs-previous: k8s-require-resource
	@$(MAKE) -s k8s-logs K8S_LOG_PREVIOUS=true
.PHONY: k8s-logs-previous

## Create a recovery-ready snapshot of the rendered Kubernetes desired state
k8s-backup: k8s-require-overlay
	@set -euo pipefail; \
	umask 077; \
	mkdir -p "$(K8S_BACKUP_DIR)"; \
	tmp_file="$$(mktemp "$(K8S_BACKUP_DIR)/.snapshot.XXXXXX")"; \
	trap 'rm -f "$$tmp_file"' EXIT; \
	$(call K8S_KUSTOMIZE_BUILD,$(K8S_ENV),$(K8S_SERVICE)) > "$$tmp_file"; \
	chmod 0600 "$$tmp_file"; \
	mv "$$tmp_file" "$(K8S_BACKUP_FILE)"; \
	trap - EXIT; \
	echo "Kubernetes recovery snapshot: $(K8S_BACKUP_FILE)"
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
		$(MAKE) -s k8s-rollout-status; \
	fi
.PHONY: k8s-recover

## Apply a temporary live image hotfix with pre-change backup, rollout verification, and automatic rollback
k8s-image-hotfix: k8s-require-image-hotfix k8s-backup
	@echo "WARNING: k8s-image-hotfix changes only the live workload and does not update the declarative overlay."
	@echo "Update the Kustomize/Helm image configuration before the next k8s-deploy or the hotfix may be reverted."
	@echo "──── Current Rollout History ─────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-rollout-history

	@$(MAKE) -s k8s-confirm K8S_STACK_DIR="$(K8S_SERVICE)"

	@echo "──── Image Hotfix ────────────────────────────────────────────────────────────────────────"
	@$(K8S_TOOLS_ALIAS) kubectl set image \
		"$(K8S_RESOURCE_KIND)/$(K8S_RESOURCE_NAME)" \
		"$(K8S_CONTAINER)=$(K8S_IMAGE)" \
		--namespace "$(K8S_OPERATIONS_NAMESPACE)" \
		--kubeconfig "$(K8S_KUBECONFIG)"

	@if ! $(MAKE) -s k8s-rollout-status; then \
		echo "Image hotfix rollout failed."; \
		if [[ "$(K8S_AUTO_ROLLBACK)" == "true" ]]; then \
			echo "Automatic rollback initiated."; \
			$(MAKE) -s k8s-rollout-undo; \
			$(MAKE) -s k8s-rollout-status; \
		fi; \
		exit 1; \
	fi

	@echo "Image hotfix completed; reconcile the declarative overlay before the next deployment."
.PHONY: k8s-image-hotfix

## Roll back a Kubernetes workload to its previous or explicitly selected revision
k8s-rollback: k8s-require-env k8s-require-resource
	@echo "──── Rollout History ─────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-rollout-history

	@$(MAKE) -s k8s-confirm K8S_STACK_DIR="$(K8S_SERVICE)"

	@$(MAKE) -s k8s-rollout-undo
	@$(MAKE) -s k8s-rollout-status
.PHONY: k8s-rollback
