# SPDX-License-Identifier: Apache-2.0

ifneq (,$(wildcard .env))
	include .env
	export
endif

# Define Variables

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:

HELM_RELEASE_NAME ?= mychart
HELM_CHART_DIR ?= charts
HELM_VALUES_FILE ?= values.yaml
K8S_ENV ?= local
K8S_IMAGE ?=
K8S_IMAGE_TAG ?= latest
K8S_NAMESPACE ?= default
K8S_KUSTOMIZE_BIN ?= kustomize
K8S_KUBECONFIG ?= examples/config/kubeconfig.yaml
K8S_STACK_DIR ?= dependency-track
K8S_WAIT_TIMEOUT ?= 180s
K8S_CONFIRM ?= false

KIND_CLUSTER_NAME ?= template-k8s
KIND_CONFIG ?= examples/kind/cluster.yaml
KIND_PROVIDER ?= docker
KIND_REGISTRY_ENABLED ?= true
KIND_REGISTRY_NAME ?= kind-registry
KIND_REGISTRY_PORT ?= 5001
KIND_REGISTRY_IMAGE ?= registry:3
KIND_DELETE_REGISTRY ?= false
KIND_LOG_DIR ?= .run/kind

K8S_INGRESS_ENGINE ?= cloud-provider-kind
K8S_INGRESS_PROVIDER_PID ?= .run/cloud-provider-kind.pid
K8S_INGRESS_PROVIDER_LOG ?= .run/cloud-provider-kind.log

export KIND_EXPERIMENTAL_PROVIDER := $(KIND_PROVIDER)

# Define Targets

default: help

help:
	@awk 'BEGIN {printf "Tasks\n\tA collection of tasks used in the current project.\n\n"}'
	@awk 'BEGIN {printf "Usage\n\tmake $(shell tput -Txterm setaf 6)<task>$(shell tput -Txterm sgr0)\n\n"}' $(MAKEFILE_LIST)
	@awk '/^##/{c=substr($$0,3);next}c&&/^[[:alpha:]][[:alnum:]_-]+:/{print "$(shell tput -Txterm setaf 6)\t" substr($$1,1,index($$1,":")) "$(shell tput -Txterm sgr0)",c}1{c=0}' $(MAKEFILE_LIST) | column -s: -t
.PHONY: help

# ── Setup & Teardown ─────────────────────────────────────────────────────────────────────────────

## Initialize a software development workspace with requisites
bootstrap:
	cd $(@D)/scripts && ./bootstrap.sh
.PHONY: bootstrap

## Install and configure all dependencies essential for development
setup:
	cd $(@D)/scripts && ./setup.sh
.PHONY: setup

## Remove development artifacts and restore the host to its pre-setup state
teardown:
	cd $(@D)/scripts && ./teardown.sh
.PHONY: teardown

# ── Local Kubernetes: kind ───────────────────────────────────────────────────────────────────────

## Verify required local Kubernetes tooling and runtime readiness
k8s-doctor:
	@missing=0
	@for bin in kind kubectl docker helm $(K8S_KUSTOMIZE_BIN); do \
		if ! command -v $$bin >/dev/null 2>&1; then \
			echo "missing required command: $$bin" >&2; \
			missing=1; \
		fi; \
	done
	@if [[ "$(K8S_INGRESS_ENGINE)" == "cloud-provider-kind" ]] && ! command -v cloud-provider-kind >/dev/null 2>&1; then \
		echo "missing required command: cloud-provider-kind" >&2; \
		missing=1; \
	fi
	@if ! docker info >/dev/null 2>&1; then \
		echo "container runtime is not ready: docker info failed" >&2; \
		missing=1; \
	fi
	@if [[ $$missing -ne 0 ]]; then \
		exit 127; \
	fi
	@echo "local Kubernetes dependencies are ready"
.PHONY: k8s-doctor

## Set up the local Kubernetes development environment with kind
k8s-setup: k8s-doctor kind-registry-up kind-create kind-registry-configure k8s-ingress-provider-up k8s-wait k8s-monitor-status
.PHONY: k8s-setup

## Tear down the local Kubernetes development environment
k8s-teardown: k8s-ingress-provider-down kind-delete
	@if [[ "$(KIND_DELETE_REGISTRY)" == "true" ]]; then \
		$(MAKE) -s kind-registry-down; \
	else \
		echo "keeping local registry container '$(KIND_REGISTRY_NAME)' (set KIND_DELETE_REGISTRY=true to remove it)"; \
	fi
.PHONY: k8s-teardown

## Recreate the local Kubernetes development environment from scratch
k8s-reset:
	@$(MAKE) -s k8s-teardown KIND_DELETE_REGISTRY=$(KIND_DELETE_REGISTRY)
	@$(MAKE) -s k8s-setup
.PHONY: k8s-reset

## Create the kind cluster if it does not already exist
kind-create:
	@mkdir -p "$(dir $(K8S_KUBECONFIG))" "$(KIND_LOG_DIR)" .run
	@if kind get clusters | grep -qx "$(KIND_CLUSTER_NAME)"; then \
		echo "kind cluster '$(KIND_CLUSTER_NAME)' already exists"; \
	else \
		echo "creating kind cluster '$(KIND_CLUSTER_NAME)'"; \
		kind create cluster \
			--name "$(KIND_CLUSTER_NAME)" \
			--config "$(KIND_CONFIG)" \
			--wait "$(K8S_WAIT_TIMEOUT)" \
			--kubeconfig "$(K8S_KUBECONFIG)"; \
	fi
	@kind export kubeconfig --name "$(KIND_CLUSTER_NAME)" --kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: kind-create

## Delete the kind cluster; safe to run repeatedly
kind-delete:
	@kind delete cluster --name "$(KIND_CLUSTER_NAME)"
.PHONY: kind-delete

## Export kubeconfig for the local kind cluster
kind-kubeconfig:
	@mkdir -p "$(dir $(K8S_KUBECONFIG))"
	@kind export kubeconfig --name "$(KIND_CLUSTER_NAME)" --kubeconfig "$(K8S_KUBECONFIG)"
	@echo "export KUBECONFIG=$(K8S_KUBECONFIG)"
.PHONY: kind-kubeconfig

## Start a localhost container registry for kind images
kind-registry-up:
	@if [[ "$(KIND_REGISTRY_ENABLED)" != "true" ]]; then \
		echo "local registry disabled"; \
		exit 0; \
	fi
	@if docker inspect "$(KIND_REGISTRY_NAME)" >/dev/null 2>&1; then \
		if [[ "$$(docker inspect -f '{{.State.Running}}' "$(KIND_REGISTRY_NAME)")" != "true" ]]; then \
			echo "starting local registry '$(KIND_REGISTRY_NAME)'"; \
			docker start "$(KIND_REGISTRY_NAME)" >/dev/null; \
		else \
			echo "local registry '$(KIND_REGISTRY_NAME)' already running"; \
		fi; \
	else \
		echo "creating local registry '$(KIND_REGISTRY_NAME)' on localhost:$(KIND_REGISTRY_PORT)"; \
		docker run -d --restart=always \
			-p "127.0.0.1:$(KIND_REGISTRY_PORT):5000" \
			--network bridge \
			--name "$(KIND_REGISTRY_NAME)" \
			"$(KIND_REGISTRY_IMAGE)" >/dev/null; \
	fi
.PHONY: kind-registry-up

## Configure kind nodes to pull images from the localhost registry
kind-registry-configure:
	@if [[ "$(KIND_REGISTRY_ENABLED)" != "true" ]]; then \
		echo "local registry disabled"; \
		exit 0; \
	fi
	@if docker network inspect kind >/dev/null 2>&1; then \
		if [[ "$$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$(KIND_REGISTRY_NAME)" 2>/dev/null || echo null)" == "null" ]]; then \
			docker network connect kind "$(KIND_REGISTRY_NAME)"; \
		fi; \
	fi
	@REGISTRY_DIR="/etc/containerd/certs.d/localhost:$(KIND_REGISTRY_PORT)"; \
	for node in $$(kind get nodes --name "$(KIND_CLUSTER_NAME)"); do \
		docker exec "$$node" mkdir -p "$$REGISTRY_DIR"; \
		printf '[host."http://$(KIND_REGISTRY_NAME):5000"]\n' | docker exec -i "$$node" cp /dev/stdin "$$REGISTRY_DIR/hosts.toml"; \
	done
	@printf '%s\n' \
		'apiVersion: v1' \
		'kind: ConfigMap' \
		'metadata:' \
		'  name: local-registry-hosting' \
		'  namespace: kube-public' \
		'data:' \
		'  localRegistryHosting.v1: |' \
		'    host: "localhost:$(KIND_REGISTRY_PORT)"' \
		'    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"' \
		| kubectl --kubeconfig "$(K8S_KUBECONFIG)" apply -f -
.PHONY: kind-registry-configure

## Remove the local kind registry container; safe to run repeatedly
kind-registry-down:
	@docker rm -f "$(KIND_REGISTRY_NAME)" >/dev/null 2>&1 || true
	@echo "local registry '$(KIND_REGISTRY_NAME)' removed or already absent"
.PHONY: kind-registry-down

## Load a locally built image into the kind cluster; usage: make kind-load-image K8S_IMAGE=name:tag
kind-load-image:
	@if [[ -z "$(K8S_IMAGE)" ]]; then \
		echo "usage: make kind-load-image K8S_IMAGE=name:tag" >&2; \
		exit 2; \
	fi
	@kind load docker-image "$(K8S_IMAGE)" --name "$(KIND_CLUSTER_NAME)"
.PHONY: kind-load-image

## Push an image to the local kind registry; usage: make kind-push-image K8S_IMAGE=name:tag
kind-push-image:
	@if [[ -z "$(K8S_IMAGE)" ]]; then \
		echo "usage: make kind-push-image K8S_IMAGE=name:tag" >&2; \
		exit 2; \
	fi
	@$(MAKE) -s kind-registry-up
	@image_ref="$(K8S_IMAGE)"; \
	registry_image="localhost:$(KIND_REGISTRY_PORT)/$${image_ref##*/}"; \
	docker tag "$$image_ref" "$$registry_image"; \
	docker push "$$registry_image"; \
	echo "$$registry_image"
.PHONY: kind-push-image

## Start the configured ingress provider engine
k8s-ingress-provider-up:
	@mkdir -p .run
	@case "$(K8S_INGRESS_ENGINE)" in \
		cloud-provider-kind) \
			if [[ -f "$(K8S_INGRESS_PROVIDER_PID)" ]] && kill -0 "$$(cat "$(K8S_INGRESS_PROVIDER_PID)")" >/dev/null 2>&1; then \
				echo "cloud-provider-kind already running with PID $$(cat "$(K8S_INGRESS_PROVIDER_PID)")"; \
			else \
				rm -f "$(K8S_INGRESS_PROVIDER_PID)"; \
				echo "starting cloud-provider-kind ingress/load-balancer engine"; \
				nohup cloud-provider-kind >"$(K8S_INGRESS_PROVIDER_LOG)" 2>&1 & \
				echo $$! > "$(K8S_INGRESS_PROVIDER_PID)"; \
				sleep 2; \
				kill -0 "$$(cat "$(K8S_INGRESS_PROVIDER_PID)")" >/dev/null 2>&1 || { cat "$(K8S_INGRESS_PROVIDER_LOG)" >&2; exit 1; }; \
			fi \
			;; \
		none) \
			echo "ingress provider engine disabled" \
			;; \
		*) \
			echo "unsupported K8S_INGRESS_ENGINE='$(K8S_INGRESS_ENGINE)'" >&2; \
			exit 2 \
			;; \
	esac
.PHONY: k8s-ingress-provider-up

## Stop the configured ingress provider engine; safe to run repeatedly
k8s-ingress-provider-down:
	@if [[ -f "$(K8S_INGRESS_PROVIDER_PID)" ]]; then \
		pid="$$(cat "$(K8S_INGRESS_PROVIDER_PID)")"; \
		if kill -0 "$$pid" >/dev/null 2>&1; then \
			echo "stopping cloud-provider-kind PID $$pid"; \
			kill "$$pid"; \
		fi; \
		rm -f "$(K8S_INGRESS_PROVIDER_PID)"; \
	else \
		echo "ingress provider engine is not managed by this workspace or already stopped"; \
	fi
.PHONY: k8s-ingress-provider-down

## Show ingress provider engine status
k8s-ingress-provider-status:
	@case "$(K8S_INGRESS_ENGINE)" in \
		cloud-provider-kind) \
			if [[ -f "$(K8S_INGRESS_PROVIDER_PID)" ]] && kill -0 "$$(cat "$(K8S_INGRESS_PROVIDER_PID)")" >/dev/null 2>&1; then \
				echo "cloud-provider-kind running with PID $$(cat "$(K8S_INGRESS_PROVIDER_PID)")"; \
			else \
				echo "cloud-provider-kind not running under workspace management"; \
			fi \
			;; \
		none) echo "ingress provider engine disabled" ;; \
		*) echo "unsupported K8S_INGRESS_ENGINE='$(K8S_INGRESS_ENGINE)'" >&2; exit 2 ;; \
	esac
.PHONY: k8s-ingress-provider-status

## Wait until the local kind cluster is ready for workloads
k8s-wait:
	@kubectl --kubeconfig "$(K8S_KUBECONFIG)" wait --for=condition=Ready node --all --timeout="$(K8S_WAIT_TIMEOUT)"
	@kubectl --kubeconfig "$(K8S_KUBECONFIG)" -n kube-system rollout status deployment/coredns --timeout="$(K8S_WAIT_TIMEOUT)"
	@if kubectl --kubeconfig "$(K8S_KUBECONFIG)" get namespace local-path-storage >/dev/null 2>&1; then \
		kubectl --kubeconfig "$(K8S_KUBECONFIG)" -n local-path-storage rollout status deployment/local-path-provisioner --timeout="$(K8S_WAIT_TIMEOUT)"; \
	fi
.PHONY: k8s-wait

## Assert the local kind cluster exists and is reachable
k8s-ensure-ready:
	@if ! kind get clusters | grep -qx "$(KIND_CLUSTER_NAME)"; then \
		echo "kind cluster '$(KIND_CLUSTER_NAME)' does not exist; run 'make k8s-setup'" >&2; \
		exit 1; \
	fi
	@kubectl --kubeconfig "$(K8S_KUBECONFIG)" cluster-info >/dev/null
	@$(MAKE) -s k8s-wait
.PHONY: k8s-ensure-ready

# ── Kubernetes Deploy & Destroy ──────────────────────────────────────────────────────────────────

# Interactive user confirmation before proceeding with Kubernetes Deploy & Destroy
k8s-confirm:
	@if [[ "$(K8S_CONFIRM)" != "true" ]]; then \
		exit 0; \
	fi
	@echo ""
	@read -r -p "Confirm: Proceed with Kubernetes in '$(K8S_ENV)' targeting '$(K8S_STACK_DIR)'? [yes $(K8S_ENV)/no] " confirm; \
		if [[ "$$confirm" != "yes $(K8S_ENV)" ]]; then \
			echo "Aborted."; \
			exit 1; \
		fi
.PHONY: k8s-confirm

# Usage: make k8s-deploy-<env>
#
# Template to deploy Kubernetes manifests integrated Helm charts and Kustomize environment-specific overlays
template-k8s-deploy-%: k8s-ensure-ready
	@$(MAKE) -s k8s-confirm K8S_ENV=$* K8S_STACK_DIR=$(K8S_STACK_DIR)
	@test -d "manifests/overlays/$*/$(K8S_STACK_DIR)" || { echo "missing overlay: manifests/overlays/$*/$(K8S_STACK_DIR)" >&2; exit 1; }
	@$(K8S_KUSTOMIZE_BIN) build "manifests/overlays/$*/$(K8S_STACK_DIR)" \
		--enable-helm --load-restrictor=LoadRestrictionsNone \
		| kubectl apply --kubeconfig "$(K8S_KUBECONFIG)" -f -
.PHONY: template-k8s-deploy-%

## Deploy Kubernetes manifests for Dependency-Track
k8s-deploy-dependency-track:
	@$(MAKE) template-k8s-deploy-$(K8S_ENV) K8S_STACK_DIR=dependency-track
.PHONY: k8s-deploy-dependency-track

# Usage: make k8s-destroy-<env>
#
# Template to destroy Kubernetes manifests integrated Helm charts and Kustomize environment-specific overlays
template-k8s-destroy-%: k8s-ensure-ready
	@$(MAKE) -s k8s-confirm K8S_ENV=$* K8S_STACK_DIR=$(K8S_STACK_DIR)
	@test -d "manifests/overlays/$*/$(K8S_STACK_DIR)" || { echo "missing overlay: manifests/overlays/$*/$(K8S_STACK_DIR)" >&2; exit 1; }
	@$(K8S_KUSTOMIZE_BIN) build "manifests/overlays/$*/$(K8S_STACK_DIR)" \
		--enable-helm --load-restrictor=LoadRestrictionsNone \
		| kubectl delete --ignore-not-found=true --kubeconfig "$(K8S_KUBECONFIG)" -f -
.PHONY: template-k8s-destroy-%

## Destroy Kubernetes manifests for Dependency-Track
k8s-destroy-dependency-track:
	@$(MAKE) template-k8s-destroy-$(K8S_ENV) K8S_STACK_DIR=dependency-track
.PHONY: k8s-destroy-dependency-track

# ── Kubernetes Rendering ─────────────────────────────────────────────────────────────────────────

# Template to render Kubernetes manifests using Kustomize and Helm charts
template-k8s-render-%:
	@mkdir -p render/kustomize/$*/$(K8S_STACK_DIR)
	@$(K8S_KUSTOMIZE_BIN) build \
		manifests/overlays/$*/$(K8S_STACK_DIR) \
		--enable-helm --load-restrictor=LoadRestrictionsNone \
		--output=./render/kustomize/$*/$(K8S_STACK_DIR)
.PHONY: template-k8s-render-%

# Render Kubernetes manifests for Dependency-Track
k8s-render-dependency-track:
	@$(MAKE) template-k8s-render-$(K8S_ENV) K8S_STACK_DIR=dependency-track
.PHONY: k8s-render-dependency-track

## Render all Kubernetes manifests
k8s-render-manifests:
	@$(MAKE) -s k8s-render-dependency-track
.PHONY: k8s-render-manifests

# ── Kubernetes Status & Monitoring ───────────────────────────────────────────────────────────────

# List all services
k8s-list-service:
	kubectl get services -A --kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-list-service

# List all namespaces
k8s-list-namespace:
	kubectl get namespaces --kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-list-namespace

# List all pods
k8s-list-pod:
	kubectl get pods -A --kubeconfig "$(K8S_KUBECONFIG)"
.PHONY: k8s-list-pod

# List all ingress controllers
k8s-list-controller:
	kubectl get ingressclass --kubeconfig "$(K8S_KUBECONFIG)" || true
.PHONY: k8s-list-controller

# List all ingress resources
k8s-list-ingress:
	kubectl get ingress -A --kubeconfig "$(K8S_KUBECONFIG)" || true
.PHONY: k8s-list-ingress

# List all storage classes
k8s-list-storage:
	kubectl get storageclass --kubeconfig "$(K8S_KUBECONFIG)" || true
.PHONY: k8s-list-storage

## Monitor the status of Kubernetes resources
k8s-monitor-status:
	@echo "──── K8s Context ─────────────────────────────────────────────────────────────────────────"
	@kubectl config current-context --kubeconfig "$(K8S_KUBECONFIG)" || true
	@echo "──── K8s Nodes ───────────────────────────────────────────────────────────────────────────"
	@kubectl get nodes -o wide --kubeconfig "$(K8S_KUBECONFIG)" || true
	@echo "──── K8s Services ────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-service
	@echo "──── K8s Namespaces ──────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-namespace
	@echo "──── K8s Ingress Provider ────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-ingress-provider-status || true
	@echo "──── K8s Ingress Classes ────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-controller
	@echo "──── K8s Ingress Resources ───────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-ingress
	@echo "──── K8s Storage ─────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-storage
	@echo "──── K8s Pods ────────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-pod
.PHONY: k8s-monitor-status

## Export kind logs for diagnostics
k8s-export-logs:
	@mkdir -p "$(KIND_LOG_DIR)"
	@kind export logs --name "$(KIND_CLUSTER_NAME)" "$(KIND_LOG_DIR)"
.PHONY: k8s-export-logs

# ── Helm Charts ──────────────────────────────────────────────────────────────────────────────────

# Vendor Helm chart for Dependency-Track
helm-vendor-dependency-track:
	helm repo add dependency-track https://dependencytrack.github.io/helm-charts
	helm pull dependency-track/dependency-track --version 0.36.0 --untar --untardir charts/
.PHONY: helm-vendor-dependency-track

# Vendor Helm chart for PostgreSQL
helm-vendor-postgresql:
	helm repo add bitnami https://charts.bitnami.com/bitnami
	helm pull bitnami/postgresql --version 16.7.27 --untar --untardir charts/
.PHONY: helm-vendor-postgresql

# Vendor Helm chart for Traefik
helm-vendor-traefik:
	helm repo add traefik https://traefik.github.io/charts
	helm pull traefik/traefik --version 37.0.0 --untar --untardir charts/
.PHONY: helm-vendor-traefik

## Vendor all Helm charts
helm-vendor-charts:
	@$(MAKE) helm-vendor-dependency-track
	@$(MAKE) helm-vendor-postgresql
	@$(MAKE) helm-vendor-traefik
.PHONY: helm-vendor-charts

# ── Helm Charts Rendering ────────────────────────────────────────────────────────────────────────

# Render Helm charts templates with specified parameters
helm-render:
	@helm template \
		$(HELM_RELEASE_NAME) \
		$(HELM_CHART_DIR) \
		--namespace=$(K8S_NAMESPACE) \
		--values=$(HELM_VALUES_FILE) \
		--set image.tag=$(K8S_IMAGE_TAG) \
		--output-dir=./render/charts
.PHONY: helm-render

# Render Helm chart for Dependency-Track
helm-render-dependency-track:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=dependency-track \
		HELM_CHART_DIR="charts/dependency-track" \
		HELM_VALUES_FILE="charts/dependency-track/values.yaml" \
		K8S_NAMESPACE=default \
		K8S_IMAGE_TAG="v1.0.0"
.PHONY: helm-render-dependency-track

# Render Helm chart for Traefik
helm-render-traefik:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=traefik \
		HELM_CHART_DIR="charts/traefik" \
		HELM_VALUES_FILE="charts/traefik/values.yaml" \
		K8S_NAMESPACE=default \
		K8S_IMAGE_TAG="v3.0.0"
.PHONY: helm-render-traefik

# Render Helm chart for PostgreSQL
helm-render-postgresql:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=postgresql \
		HELM_CHART_DIR="charts/postgresql" \
		HELM_VALUES_FILE="charts/postgresql/values.yaml" \
		K8S_NAMESPACE=default \
		K8S_IMAGE_TAG="v16.0.0"
.PHONY: helm-render-postgresql

## Render all Helm charts
helm-render-charts:
	@$(MAKE) -s helm-render-dependency-track
	@$(MAKE) -s helm-render-traefik
	@$(MAKE) -s helm-render-postgresql
.PHONY: helm-render-charts

# ── Secrets Manager ──────────────────────────────────────────────────────────────────────────────

SECRETS_SOPS_UID ?= sops-k8s

# Usage: make secrets-gpg-generate SECRETS_SOPS_UID=<uid>
#
## Generate a new GPG key pair for SOPS with the specified UID
secrets-gpg-generate:
	@gpg --batch --quiet --passphrase '' --quick-generate-key "$(SECRETS_SOPS_UID)" ed25519 cert,sign 0
	@NEW_FPR="$$(gpg --list-keys --with-colons "$(SECRETS_SOPS_UID)" | awk -F: '/^fpr:/ {print $$10; exit}')"; \
	gpg --batch --quiet --passphrase '' --quick-add-key "$${NEW_FPR}" cv25519 encrypt 0
.PHONY: secrets-gpg-generate

# Usage: make secrets-gpg-export SECRETS_SOPS_UID=<uid>
#
## Export the GPG key pair for SOPS with the specified UID to ASCII files
secrets-gpg-export:
	@if [[ -z "$(SECRETS_SOPS_UID)" ]]; then \
		echo "usage: make secrets-gpg-export SECRETS_SOPS_UID=<uid>" >&2; \
		exit 1; \
	fi
	@gpg --armor --export "$(SECRETS_SOPS_UID)" > "$(SECRETS_SOPS_UID)-public.asc"
	@gpg --armor --export-secret-keys "$(SECRETS_SOPS_UID)" > "$(SECRETS_SOPS_UID)-private.asc"
.PHONY: secrets-gpg-export
