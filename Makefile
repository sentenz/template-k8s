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
K8S_IMAGE_TAG ?= latest
K8S_NAMESPACE ?= default
K8S_KUSTOMIZE_BIN := kustomize
K8S_KUBECONFIG ?= examples/config/kubeconfig.yaml
K8S_STACK_DIR ?= manifests/overlays

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

# ── Kubernetes Setup & Teardown ──────────────────────────────────────────────────────────────────

## Set up the development environment using Docker Compose
k8s-setup:
	docker compose -f $(CURDIR)/examples/docker-compose.yaml up --scale k3s-agent=2 -d
.PHONY: k8s-setup

## Tear down the development environment using Docker Compose
k8s-teardown:
	docker compose -f $(CURDIR)/examples/docker-compose.yaml down -v
.PHONY: k8s-teardown

# ── Kubernetes Deploy & Destroy ──────────────────────────────────────────────────────────────────

# Interactive user confirmation before proceeding with Kubernetes Deploy & Destroy
k8s-confirm:
	@echo ""
	@read -r -p "Confirm: Proceed with 'Kubernetes' in '$(K8S_ENV)'$(if $(K8S_STACK_DIR), targeting '$(K8S_STACK_DIR)',)? [yes $(K8S_ENV)/no] " confirm; \
		if [[ "$$confirm" != "yes $(K8S_ENV)" ]]; then \
			echo "Aborted."; \
			exit 1; \
		fi
.PHONY: k8s-confirm

# Usage: make k8s-deploy-<env>
#
# Template to deploy Kubernetes manifests integrated Helm charts and Kustomize environment-specific overlays
template-k8s-deploy-%:
	@$(MAKE) -s k8s-confirm
	@$(K8S_KUSTOMIZE_BIN) build manifests/overlays/$*/$(K8S_STACK_DIR) \
		--enable-helm --load-restrictor=LoadRestrictionsNone \
		| kubectl apply --kubeconfig $(K8S_KUBECONFIG) -f -
.PHONY: template-k8s-deploy-%

## Deploy Kubernetes manifests for Dependency-Track
k8s-deploy-dependency-track:
	@$(MAKE) template-k8s-deploy-$(K8S_ENV) K8S_STACK_DIR=dependency-track
.PHONY: k8s-deploy-dependency-track

# Usage: make k8s-destroy-<env>
#
# Template to destroy Kubernetes manifests integrated Helm charts and Kustomize environment-specific overlays
template-k8s-destroy-%:
	@$(MAKE) -s k8s-confirm
	@$(K8S_KUSTOMIZE_BIN) build manifests/overlays/$*/$(K8S_STACK_DIR) \
		--enable-helm --load-restrictor=LoadRestrictionsNone \
		| kubectl delete --kubeconfig $(K8S_KUBECONFIG) -f -
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
	kubectl get services --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-list-service

# List all namespaces
k8s-list-namespace:
	kubectl get namespaces --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-list-namespace

# List all pods
k8s-list-pod:
	kubectl get pods -A --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-list-pod

# List all ingress controllers
k8s-list-controller:
	kubectl get ingressclass --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-list-controller

## Monitor the status of Kubernetes resources
k8s-monitor-status:
	@echo "──── K8s Services ────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-service
	@echo "──── K8s Namespaces ──────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-namespace
	@echo "──── K8s Ingress Controllers ─────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-controller
	@echo "──── K8s Pods ────────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-list-pod
.PHONY: k8s-monitor-status

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
## Generate a new GPG key pair for SOPS
secrets-gpg-generate:
	@gpg --batch --quiet --passphrase '' --quick-generate-key "$(SECRETS_SOPS_UID)" ed25519 cert,sign 0
	@NEW_FPR="$$(gpg --list-keys --with-colons "$(SECRETS_SOPS_UID)" | awk -F: '/^fpr:/ {print $$10; exit}')"
	@gpg --batch --quiet --passphrase '' --quick-add-key "$${NEW_FPR}" cv25519 encrypt 0
.PHONY: secrets-gpg-generate

# Usage: make secrets-gpg-show SECRETS_SOPS_UID=<uid>
#
## Print the GPG key fingerprint for SOPS (.sops.yaml)
secrets-gpg-show:
	@FPR="$$(gpg --list-keys --with-colons "$(SECRETS_SOPS_UID)" | awk -F: '/^fpr:/ {print $$10; exit}')"; \
	if [ -z "$${FPR}" ]; then \
		echo "error: no fingerprint found for UID '$(SECRETS_SOPS_UID)'" >&2; \
		exit 1; \
	fi; \
	echo -e "UID: $(SECRETS_SOPS_UID)\nFingerprint: $${FPR}"
.PHONY: secrets-gpg-show

# Usage: make secrets-gpg-remove SECRETS_SOPS_UID=<uid>
#
## Remove an existing GPG key for SOPS (interactive)
secrets-gpg-remove:
	if ! gpg --list-keys "$(SECRETS_SOPS_UID)" >/dev/null 2>&1; then
		echo "warning: no key found for '$(SECRETS_SOPS_UID)'" >&2
		exit 0
	fi
	echo "info: deleting key for '$(SECRETS_SOPS_UID)'"
	# Delete private key first, then public key
	gpg --yes --delete-secret-keys "$(SECRETS_SOPS_UID)"
	gpg --yes --delete-keys "$(SECRETS_SOPS_UID)"
.PHONY: secrets-gpg-remove

# Usage: make secrets-sops-encrypt <files>
#
## Encrypt file using SOPS
secrets-sops-encrypt:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-sops-encrypt <files>"; \
		exit 1; \
	fi

	export PATH="$$PATH:$(shell go env GOPATH 2>/dev/null)/bin"
	@for file in $(filter-out $@,$(MAKECMDGOALS)); do \
		if [ -f "$$file" ]; then \
			sops --encrypt --in-place "$$file"; \
		else \
			echo "Skipping (not found): $$file" >&2; \
		fi; \
	done
.PHONY: secrets-sops-encrypt

# Usage: make secrets-sops-decrypt <files>
#
## Decrypt file using SOPS
secrets-sops-decrypt:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-sops-encrypt <files>"; \
		exit 1; \
	fi

	export PATH="$$PATH:$(shell go env GOPATH 2>/dev/null)/bin"
	@for file in $(filter-out $@,$(MAKECMDGOALS)); do \
		if [ -f "$$file" ]; then \
			sops --decrypt --in-place "$$file"; \
		else \
			echo "Skipping (not found): $$file" >&2; \
		fi; \
	done
.PHONY: secrets-sops-decrypt

# Usage: make secrets-sops-view <file>
#
## View a file encrypted with SOPS
secrets-sops-view:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-sops-view <file>"; \
		exit 1; \
	fi

	export PATH="$$PATH:$(shell go env GOPATH 2>/dev/null)/bin"
	sops --decrypt "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: secrets-sops-view

# ── Policy Manager ───────────────────────────────────────────────────────────────────────────────

POLICY_IMAGE_CONFTEST ?= openpolicyagent/conftest:v0.65.0@sha256:afa510df6d4562ebe24fb3e457da6f6d6924124140a13b51b950cc6cb1d25525

# Usage: make policy-analysis-conftest <filepath>
#
## Analyze configuration files using Conftest for policy violations and generate a report
policy-analysis-conftest:
	@mkdir -p logs/policy

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make policy-analysis-conftest <filepath>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(POLICY_IMAGE_CONFTEST)" test "$(filter-out $@,$(MAKECMDGOALS))" > logs/policy/conftest.json 2>&1
.PHONY: policy-analysis-conftest

POLICY_IMAGE_REGAL ?= ghcr.io/openpolicyagent/regal:0.37.0@sha256:a09884658f3c8c9cc30de136b664b3afdb7927712927184ba891a155a9676050

# Usage: make policy-lint-regal <filepath>
#
## Lint Rego policies using Regal and generate a report
policy-lint-regal:
	@mkdir -p logs/analysis

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make policy-lint-regal"; \
		exit 1; \
	fi

	docker pull "$(POLICY_IMAGE_REGAL)"
	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(POLICY_IMAGE_REGAL)" regal lint "$(filter-out $@,$(MAKECMDGOALS))" --format json > logs/analysis/regal.json 2>&1
.PHONY: policy-lint-regal

# ── SAST Manager ─────────────────────────────────────────────────────────────────────────────────

SAST_IMAGE_TRIVY ?= aquasec/trivy:0.68.2@sha256:05d0126976bdedcd0782a0336f77832dbea1c81b9cc5e4b3a5ea5d2ec863aca7
SAST_IMAGE_COSIGN ?= cgr.dev/chainguard/cosign:3.0.0@sha256:b6bc266358e9368be1b3d01fca889b78d5ad5a47832986e14640c34a237ef638

## Scan Infrastructure-as-Code (IaC) files for misconfigurations using Trivy and generate a report
sast-trivy-misconfig:
	@mkdir -p logs/sast

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" config --output logs/sast/trivy-misconfig.json /workspace 2>&1
.PHONY: sast-trivy-misconfig

## Scan local filesystem for vulnerabilities and misconfigurations using Trivy
sast-trivy-fs:
	@mkdir -p logs/sast

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" filesystem --output logs/sast/trivy-filesystem.json /workspace 2>&1
.PHONY: sast-trivy-fs

# Usage: make sast-trivy-image <image_name>
#
## Scan a container image for vulnerabilities using Trivy
sast-trivy-image:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-image <image_name>"; \
		exit 1; \
	fi

	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" image --output logs/sast/trivy-image.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-image

# Usage: make sast-trivy-image-license <image_name>
#
## Scan a container image for license compliance using Trivy
sast-trivy-image-license:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-image-license <image_name>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" image --scanners license --format table --output logs/sast/trivy-image-license.txt "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-image-license

# Usage: make sast-trivy-repository <repo_url>
#
## Scan a remote repository for vulnerabilities using Trivy
sast-trivy-repository:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-repository <repo_url>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" repository --output logs/sast/trivy-repository.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-repository

# Usage: make sast-trivy-rootfs <path>
#
## Scan a rootfs e.g. `/` for vulnerabilities using Trivy
sast-trivy-rootfs:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-rootfs <path>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" rootfs --output logs/sast/trivy-rootfs.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-rootfs

# Usage: make sast-trivy-sbom-scan <sbom_path>
#
## Scan SBOM for vulnerabilities using Trivy
sast-trivy-sbom-scan:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-scan <sbom_path>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" sbom --output logs/sast/trivy-sbom.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-scan

# Usage: make sast-trivy-sbom-cyclonedx-image <image_name>
#
## Generate SBOM in CycloneDX format for a container image using Trivy
sast-trivy-sbom-cyclonedx-image:
	@mkdir -p logs/sbom

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-cyclonedx-image <image_name>"; \
		exit 1; \
	fi

	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" image --format cyclonedx --output logs/sbom/sbom-image.cdx.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-cyclonedx-image

# Usage: make sast-trivy-sbom-cyclonedx-fs <path>
#
## Generate SBOM in CycloneDX format for a file system using Trivy
sast-trivy-sbom-cyclonedx-fs:
	@mkdir -p logs/sbom

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-cyclonedx-fs <path>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" filesystem --format cyclonedx --output logs/sbom/sbom-fs.cdx.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-cyclonedx-fs

# Usage: make sast-trivy-sbom-license <sbom_path>
#
## Scan SBOM for license compliance using Trivy
sast-trivy-sbom-license:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-license <sbom_path>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" sbom --scanners license --format table --output logs/sast/trivy-sbom-license.txt "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-license

# Usage: make sast-trivy-sbom-attestation <intoto_sbom_path>
#
## Scan the verified SBOM attestation using Trivy
sast-trivy-sbom-attestation:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-attestation <intoto_sbom_path>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" sbom "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: sast-trivy-sbom-attestation

# Usage: make sast-trivy-vm <vm_image_path>
#
## [EXPERIMENTAL] Scan a virtual machine image using Trivy
sast-trivy-vm:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-vm <vm_image_path>"; \
		exit 1; \
	fi

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" vm --output logs/sast/trivy-vm.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-vm

# Usage: make sast-trivy-kubernetes [target]
#
## [EXPERIMENTAL] Scan kubernetes cluster using Trivy (default `cluster`)
sast-trivy-kubernetes:
	@mkdir -p logs/sast

	@echo "Note: This requires KUBECONFIG to be mounted or available to the container. Assuming ~/.kube/config is mounted to /root/.kube/config"

	docker run --rm -v "${HOME}/.kube/config:/root/.kube/config" -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRIVY)" kubernetes --output logs/sast/trivy-kubernetes.json $(if $(filter-out $@,$(MAKECMDGOALS)),$(filter-out $@,$(MAKECMDGOALS)),cluster) 2>&1
.PHONY: sast-trivy-kubernetes

## Generate Cosign key pair
sast-cosign-generate-key-pair:
	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_COSIGN)" generate-key-pair
.PHONY: sast-cosign-generate-key-pair

# Usage: make sast-cosign-attest <image_name>
#
## Attest an image with the generated SBOM using Cosign
sast-cosign-attest:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-cosign-attest <image_name>"; \
		exit 1; \
	fi
	@if [ ! -f cosign.key ]; then \
		echo "Error: cosign.key not found. Run 'make sast-cosign-generate-key-pair' first."; \
		exit 1; \
	fi
	@if [ ! -f logs/sbom/sbom.cdx.json ]; then \
		echo "Error: logs/sbom/sbom.cdx.json not found. Run 'make sast-trivy-sbom-cyclonedx <image_name>' first."; \
		exit 1; \
	fi

	docker run --rm -v "${HOME}/.docker/config.json:/root/.docker/config.json" -v "${PWD}:/workspace" -w /workspace -e COSIGN_PASSWORD "$(SAST_IMAGE_COSIGN)" attest --key cosign.key --type cyclonedx --predicate logs/sbom/sbom.cdx.json "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: sast-cosign-attest

# Usage: make sast-cosign-verify <image_name>
#
## Verify SBOM attestation for an image using Cosign
sast-cosign-verify:
	@mkdir -p logs/sast

	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-cosign-verify <image_name>"; \
		exit 1; \
	fi
	@if [ ! -f cosign.pub ]; then \
		echo "Error: cosign.pub not found. Run 'make sast-cosign-generate-key-pair' first."; \
		exit 1; \
	fi

	docker run --rm -v "${HOME}/.docker/config.json:/root/.docker/config.json" -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_COSIGN)" verify-attestation --key cosign.pub --type cyclonedx "$(filter-out $@,$(MAKECMDGOALS))" > logs/sbom/sbom.cdx.intoto.jsonl 2> logs/sast/cosign-verify.log
.PHONY: sast-cosign-verify

















# # Define Variables

# NAMESPACE ?= default
# CONTEXT ?= default
# APP_NAME ?= mychart
# IMAGE_TAG ?= v1.0.0
# MANIFEST_DIR ?= manifests
# KUSTOMIZE_BIN := kustomize
# KUSTOMIZE_DIR ?= kustomize
# OUTPUT_FORMAT ?= yaml
# KUBECTL_FLAGS ?= --dry-run=client
# HELM_CHART_NAME ?= $(APP_NAME)
# HELM_CHART_VERSION ?= 1.0.0
# HELM_CHART_DIR ?= charts
# HELM_RELEASE_NAME ?= $(APP_NAME)
# HELM_REPO_NAME ?= myrepo
# HELM_REPO_URL ?= https://charts.example.com
# HELM_VALUES_FILE ?= values.yaml
# HELM_TIMEOUT ?= 5m

# ## List all available contexts
# k8s-context-list:
# 	kubectl config get-contexts
# .PHONY: k8s-context-list

# ## Set kubectl context (use CONTEXT=name)
# k8s-context-set:
# 	kubectl config use-context $(CONTEXT)
# .PHONY: k8s-context-set

# ## Show current context
# k8s-context-current:
# 	kubectl config current-context
# .PHONY: k8s-context-current

# # Namespace Management

# ## Create namespace (use NAMESPACE=name)
# k8s-namespace-create:
# 	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
# .PHONY: k8s-namespace-create

# ## Delete namespace (use NAMESPACE=name)
# k8s-namespace-delete:
# 	kubectl delete namespace $(NAMESPACE)
# .PHONY: k8s-namespace-delete

# ## List all namespaces
# k8s-namespace-list:
# 	kubectl get namespaces
# .PHONY: k8s-namespace-list

# ## Deploy to development environment
# k8s-deploy-dev-create:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/ --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-dev-create

# ## Deploy to staging environment
# k8s-deploy-stage-create:
# 	kubectl apply -f $(MANIFEST_DIR)/staging/ --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-stage-create

# ## Deploy to production environment
# k8s-deploy-prod-create:
# 	kubectl apply -f $(MANIFEST_DIR)/prod/ --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-prod-create

# ## Deploy all manifests
# k8s-deploy-all-create:
# 	kubectl apply -f $(MANIFEST_DIR)/ --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-all-create

# ## Update development deployment
# k8s-deploy-dev-update:
# 	kubectl rollout restart deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-dev-update

# ## Update staging deployment
# k8s-deploy-stage-update:
# 	kubectl rollout restart deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-stage-update

# ## Update production deployment
# k8s-deploy-prod-update:
# 	kubectl rollout restart deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-prod-update

# ## Delete all deployments
# k8s-deploy-all-delete:
# 	kubectl delete -f $(MANIFEST_DIR)/ --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-all-delete

# ## Preview development deployment (dry-run)
# k8s-deploy-dev-preview:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/ --namespace=$(NAMESPACE) --dry-run=client -o $(OUTPUT_FORMAT)
# .PHONY: k8s-deploy-dev-preview

# ## Create development service
# k8s-service-dev-create:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/service.yaml --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-service-dev-create

# ## Create staging service
# k8s-service-stage-create:
# 	kubectl apply -f $(MANIFEST_DIR)/staging/service.yaml --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-service-stage-create

# ## Create production service
# k8s-service-prod-create:
# 	kubectl apply -f $(MANIFEST_DIR)/prod/service.yaml --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-service-prod-create

# ## List all services
# k8s-service-all-list:
# 	kubectl get services --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-service-all-list

# ## Delete all services
# k8s-service-all-delete:
# 	kubectl delete services --all --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-service-all-delete

# ## Preview development service (dry-run)
# k8s-service-dev-preview:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/service.yaml --namespace=$(NAMESPACE) --dry-run=client -o $(OUTPUT_FORMAT)
# .PHONY: k8s-service-dev-preview

# ## List all pods
# k8s-pod-all-list:
# 	kubectl get pods --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-pod-all-list

# ## Show logs for all pods
# k8s-pod-all-logs:
# 	kubectl logs -l app=$(APP_NAME) --namespace=$(NAMESPACE) --tail=100
# .PHONY: k8s-pod-all-logs

# ## Show logs for development pods
# k8s-pod-dev-logs:
# 	kubectl logs -l app=$(APP_NAME),env=dev --namespace=$(NAMESPACE) --tail=100
# .PHONY: k8s-pod-dev-logs

# ## Show logs for staging pods
# k8s-pod-stage-logs:
# 	kubectl logs -l app=$(APP_NAME),env=staging --namespace=$(NAMESPACE) --tail=100
# .PHONY: k8s-pod-stage-logs

# ## Show logs for production pods
# k8s-pod-prod-logs:
# 	kubectl logs -l app=$(APP_NAME),env=prod --namespace=$(NAMESPACE) --tail=100
# .PHONY: k8s-pod-prod-logs

# ## Delete all pods
# k8s-pod-all-delete:
# 	kubectl delete pods --all --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-pod-all-delete

# ## Create development configmap
# k8s-configmap-dev-create:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/configmap.yaml -n $(NAMESPACE)
# .PHONY: k8s-configmap-dev-create

# ## Create staging configmap
# k8s-configmap-stage-create:
# 	kubectl apply -f $(MANIFEST_DIR)/staging/configmap.yaml -n $(NAMESPACE)
# .PHONY: k8s-configmap-stage-create

# ## Create production configmap
# k8s-configmap-prod-create:
# 	kubectl apply -f $(MANIFEST_DIR)/prod/configmap.yaml -n $(NAMESPACE)
# .PHONY: k8s-configmap-prod-create

# ## List all configmaps
# k8s-configmap-all-list:
# 	kubectl get configmaps -n $(NAMESPACE)
# .PHONY: k8s-configmap-all-list

# ## Delete all configmaps
# k8s-configmap-all-delete:
# 	kubectl delete configmaps --all -n $(NAMESPACE)
# .PHONY: k8s-configmap-all-delete

# ## Create development secret
# k8s-secret-dev-create:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/secret.yaml -n $(NAMESPACE)
# .PHONY: k8s-secret-dev-create

# ## Create staging secret
# k8s-secret-stage-create:
# 	kubectl apply -f $(MANIFEST_DIR)/staging/secret.yaml -n $(NAMESPACE)
# .PHONY: k8s-secret-stage-create

# ## Create production secret
# k8s-secret-prod-create:
# 	kubectl apply -f $(MANIFEST_DIR)/prod/secret.yaml -n $(NAMESPACE)
# .PHONY: k8s-secret-prod-create

# ## List all secrets
# k8s-secret-all-list:
# 	kubectl get secrets -n $(NAMESPACE)
# .PHONY: k8s-secret-all-list

# ## Delete all secrets
# k8s-secret-all-delete:
# 	kubectl delete secrets --all -n $(NAMESPACE)
# .PHONY: k8s-secret-all-delete

# ## Create development ingress
# k8s-ingress-dev-create:
# 	kubectl apply -f $(MANIFEST_DIR)/dev/ingress.yaml -n $(NAMESPACE)
# .PHONY: k8s-ingress-dev-create

# ## Create staging ingress
# k8s-ingress-stage-create:
# 	kubectl apply -f $(MANIFEST_DIR)/staging/ingress.yaml -n $(NAMESPACE)
# .PHONY: k8s-ingress-stage-create

# ## Create production ingress
# k8s-ingress-prod-create:
# 	kubectl apply -f $(MANIFEST_DIR)/prod/ingress.yaml -n $(NAMESPACE)
# .PHONY: k8s-ingress-prod-create

# ## List all ingresses
# k8s-ingress-all-list:
# 	kubectl get ingress -n $(NAMESPACE)
# .PHONY: k8s-ingress-all-list

# ## Delete all ingresses
# k8s-ingress-all-delete:
# 	kubectl delete ingress --all -n $(NAMESPACE)
# .PHONY: k8s-ingress-all-delete

# ## Check status of all resources
# k8s-status-all-check:
# 	kubectl get all --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-status-all-check

# ## List all events
# k8s-events-all-list:
# 	kubectl get events --namespace=$(NAMESPACE) --sort-by=.metadata.creationTimestamp -o $(OUTPUT_FORMAT)
# .PHONY: k8s-events-all-list

# ## Describe a specific pod (use POD_NAME=name)
# k8s-describe-pod:
# 	kubectl describe pods/$(POD_NAME) --namespace=$(NAMESPACE)
# .PHONY: k8s-describe-pod

# ## Execute shell in pod (use POD_NAME=name)
# k8s-exec-pod:
# 	kubectl exec -it pods/$(POD_NAME) --namespace=$(NAMESPACE) -- /bin/sh
# .PHONY: k8s-exec-pod

# ## Port forward to service (use SERVICE_NAME=name LOCAL_PORT=8080 REMOTE_PORT=80)
# k8s-port-forward:
# 	kubectl port-forward services/$(SERVICE_NAME) $(LOCAL_PORT):$(REMOTE_PORT) --namespace=$(NAMESPACE)
# .PHONY: k8s-port-forward

# ## Follow logs for a specific pod (use POD_NAME=name)
# k8s-logs-follow:
# 	kubectl logs pods/$(POD_NAME) --namespace=$(NAMESPACE) --follow
# .PHONY: k8s-logs-follow

# ## List all resources in namespace
# k8s-resource-all-list:
# 	kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n $(NAMESPACE)
# .PHONY: k8s-resource-all-list

# ## Delete all resources in namespace
# k8s-resource-all-delete:
# 	kubectl delete all --all -n $(NAMESPACE)
# .PHONY: k8s-resource-all-delete

# ## Scale up development deployment (use REPLICAS=3)
# k8s-scale-dev-up:
# 	kubectl scale deployment.apps/$(APP_NAME) --replicas=$(REPLICAS) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-dev-up

# ## Scale up staging deployment (use REPLICAS=3)
# k8s-scale-stage-up:
# 	kubectl scale deployment.apps/$(APP_NAME) --replicas=$(REPLICAS) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-stage-up

# ## Scale up production deployment (use REPLICAS=5)
# k8s-scale-prod-up:
# 	kubectl scale deployment.apps/$(APP_NAME) --replicas=$(REPLICAS) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-prod-up

# ## Scale down all deployments to 0
# k8s-scale-all-down:
# 	kubectl scale deployment.apps --all --replicas=0 --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-all-down

# ## Get scale status for development deployment
# k8s-scale-dev-status:
# 	kubectl get deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) --subresource=scale -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-dev-status

# ## Get scale status for staging deployment
# k8s-scale-stage-status:
# 	kubectl get deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) --subresource=scale -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-stage-status

# ## Get scale status for production deployment
# k8s-scale-prod-status:
# 	kubectl get deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) --subresource=scale -o $(OUTPUT_FORMAT)
# .PHONY: k8s-scale-prod-status

# ## Rollback development deployment
# k8s-rollback-dev:
# 	kubectl rollout undo deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-rollback-dev

# ## Rollback staging deployment
# k8s-rollback-stage:
# 	kubectl rollout undo deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-rollback-stage

# ## Rollback production deployment
# k8s-rollback-prod:
# 	kubectl rollout undo deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-rollback-prod

# ## Show rollout history for development
# k8s-rollback-dev-history:
# 	kubectl rollout history deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE)
# .PHONY: k8s-rollback-dev-history

# ## Show rollout history for staging
# k8s-rollback-stage-history:
# 	kubectl rollout history deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE)
# .PHONY: k8s-rollback-stage-history

# ## Show rollout history for production
# k8s-rollback-prod-history:
# 	kubectl rollout history deployment.apps/$(APP_NAME) --namespace=$(NAMESPACE)
# .PHONY: k8s-rollback-prod-history

# ## Run a pod in development (use specific image tag)
# k8s-run-dev-pod:
# 	kubectl run $(APP_NAME)-dev --image=$(APP_NAME):$(IMAGE_TAG) --namespace=$(NAMESPACE) --dry-run=client -o $(OUTPUT_FORMAT)
# .PHONY: k8s-run-dev-pod

# ## Run a pod in staging (use specific image tag)
# k8s-run-stage-pod:
# 	kubectl run $(APP_NAME)-stage --image=$(APP_NAME):$(IMAGE_TAG) --namespace=$(NAMESPACE) --dry-run=client -o $(OUTPUT_FORMAT)
# .PHONY: k8s-run-stage-pod

# ## Run a pod in production (use specific image tag)
# k8s-run-prod-pod:
# 	kubectl run $(APP_NAME)-prod --image=$(APP_NAME):$(IMAGE_TAG) --namespace=$(NAMESPACE) --dry-run=client -o $(OUTPUT_FORMAT)
# .PHONY: k8s-run-prod-pod

# ## Execute pod in development (removes dry-run)
# k8s-run-dev-execute:
# 	kubectl run $(APP_NAME)-dev --image=$(APP_NAME):$(IMAGE_TAG) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-run-dev-execute

# ## Execute pod in staging (removes dry-run)
# k8s-run-stage-execute:
# 	kubectl run $(APP_NAME)-stage --image=$(APP_NAME):$(IMAGE_TAG) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-run-stage-execute

# ## Execute pod in production (removes dry-run)
# k8s-run-prod-execute:
# 	kubectl run $(APP_NAME)-prod --image=$(APP_NAME):$(IMAGE_TAG) --namespace=$(NAMESPACE) -o $(OUTPUT_FORMAT)
# .PHONY: k8s-run-prod-execute

# ## Build kustomize for development
# k8s-kustomize-dev-build:
# 	kubectl kustomize $(KUSTOMIZE_DIR)/dev
# .PHONY: k8s-kustomize-dev-build

# ## Build kustomize for staging
# k8s-kustomize-stage-build:
# 	kubectl kustomize $(KUSTOMIZE_DIR)/staging
# .PHONY: k8s-kustomize-stage-build

# ## Build kustomize for production
# k8s-kustomize-prod-build:
# 	kubectl kustomize $(KUSTOMIZE_DIR)/prod
# .PHONY: k8s-kustomize-prod-build

# ## Apply kustomize for development
# k8s-kustomize-dev-apply:
# 	kubectl apply -k $(KUSTOMIZE_DIR)/dev
# .PHONY: k8s-kustomize-dev-apply

# ## Apply kustomize for staging
# k8s-kustomize-stage-apply:
# 	kubectl apply -k $(KUSTOMIZE_DIR)/staging
# .PHONY: k8s-kustomize-stage-apply

# ## Apply kustomize for production
# k8s-kustomize-prod-apply:
# 	kubectl apply -k $(KUSTOMIZE_DIR)/prod
# .PHONY: k8s-kustomize-prod-apply

# ## Cleanup development resources
# k8s-cleanup-dev:
# 	kubectl delete -f $(MANIFEST_DIR)/dev/ -n $(NAMESPACE) --ignore-not-found=true
# .PHONY: k8s-cleanup-dev

# ## Cleanup staging resources
# k8s-cleanup-stage:
# 	kubectl delete -f $(MANIFEST_DIR)/staging/ -n $(NAMESPACE) --ignore-not-found=true
# .PHONY: k8s-cleanup-stage

# ## Cleanup production resources
# k8s-cleanup-prod:
# 	kubectl delete -f $(MANIFEST_DIR)/prod/ -n $(NAMESPACE) --ignore-not-found=true
# .PHONY: k8s-cleanup-prod

# ## Cleanup all resources
# k8s-cleanup-all:
# 	kubectl delete all --all -n $(NAMESPACE)
# .PHONY: k8s-cleanup-all

# ## Workflow setup for development
# k8s-workflow-dev:
# 	k8s-namespace-create
# 	k8s-deploy-dev-create
# 	k8s-service-dev-create
# .PHONY: k8s-workflow-dev

# ## Workflow setup for staging
# k8s-workflow-stage:
# 	k8s-namespace-create
# 	k8s-deploy-stage-create
# 	k8s-service-stage-create
# .PHONY: k8s-workflow-stage

# ## Workflow setup for production
# k8s-workflow-prod:
# 	k8s-namespace-create
# 	k8s-deploy-prod-create
# 	k8s-service-prod-create
# .PHONY: k8s-workflow-prod

# ## Add helm repository
# helm-repo-add:
# 	helm repo add $(HELM_REPO_NAME) $(HELM_REPO_URL)
# .PHONY: helm-repo-add

# ## Update helm repositories
# helm-repo-update:
# 	helm repo update
# .PHONY: helm-repo-update

# ## List helm repositories
# helm-repo-list:
# 	helm repo list
# .PHONY: helm-repo-list

# ## Remove helm repository
# helm-repo-remove:
# 	helm repo remove $(HELM_REPO_NAME)
# .PHONY: helm-repo-remove

# ## Search helm repository for charts
# helm-search-repo:
# 	helm search repo $(HELM_CHART_NAME)
# .PHONY: helm-search-repo

# ## Search helm hub for charts
# helm-search-hub:
# 	helm search hub $(HELM_CHART_NAME)
# .PHONY: helm-search-hub

# ## Create new helm chart
# helm-create-chart:
# 	helm create $(HELM_CHART_DIR)/$(HELM_CHART_NAME)
# .PHONY: helm-create-chart

# ## Lint helm chart
# helm-lint-chart:
# 	helm lint $(HELM_CHART_DIR)/$(HELM_CHART_NAME)
# .PHONY: helm-lint-chart

# ## Package helm chart
# helm-package-chart:
# 	helm package $(HELM_CHART_DIR)/$(HELM_CHART_NAME) --version $(HELM_CHART_VERSION)
# .PHONY: helm-package-chart

# ## Update helm chart dependencies
# helm-dependency-update:
# 	helm dependency update $(HELM_CHART_DIR)/$(HELM_CHART_NAME)
# .PHONY: helm-dependency-update

# ## Build helm chart dependencies
# helm-dependency-build:
# 	helm dependency build $(HELM_CHART_DIR)/$(HELM_CHART_NAME)
# .PHONY: helm-dependency-build

# ## Template helm chart for development
# helm-template-dev:
# 	helm template $(HELM_RELEASE_NAME)-dev $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-dev.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--output-dir=./render/dev
# .PHONY: helm-template-dev

# ## Template helm chart for staging
# helm-template-stage:
# 	helm template $(HELM_RELEASE_NAME)-stage $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-stage.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--output-dir=./render/staging
# .PHONY: helm-template-stage

# ## Template helm chart for production
# helm-template-prod:
# 	helm template $(HELM_RELEASE_NAME)-prod $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-prod.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--output-dir=./render/prod
# .PHONY: helm-template-prod

# ## Install helm chart in development
# helm-install-dev:
# 	helm install $(HELM_RELEASE_NAME)-dev $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--create-namespace \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-dev.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--timeout=$(HELM_TIMEOUT) \
# 		--wait
# .PHONY: helm-install-dev

# ## Install helm chart in staging
# helm-install-stage:
# 	helm install $(HELM_RELEASE_NAME)-stage $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--create-namespace \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-stage.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--timeout=$(HELM_TIMEOUT) \
# 		--wait
# .PHONY: helm-install-stage

# ## Install helm chart in production
# helm-install-prod:
# 	helm install $(HELM_RELEASE_NAME)-prod $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--create-namespace \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-prod.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--timeout=$(HELM_TIMEOUT) \
# 		--wait
# .PHONY: helm-install-prod

# ## Preview helm install for development (dry-run)
# helm-install-dev-preview:
# 	helm install $(HELM_RELEASE_NAME)-dev $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-dev.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--dry-run
# .PHONY: helm-install-dev-preview

# ## Upgrade helm release in development
# helm-upgrade-dev:
# 	helm upgrade $(HELM_RELEASE_NAME)-dev $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-dev.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--timeout=$(HELM_TIMEOUT) \
# 		--wait
# .PHONY: helm-upgrade-dev

# ## Upgrade helm release in staging
# helm-upgrade-stage:
# 	helm upgrade $(HELM_RELEASE_NAME)-stage $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-stage.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--timeout=$(HELM_TIMEOUT) \
# 		--wait
# .PHONY: helm-upgrade-stage

# ## Upgrade helm release in production
# helm-upgrade-prod:
# 	helm upgrade $(HELM_RELEASE_NAME)-prod $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-prod.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--timeout=$(HELM_TIMEOUT) \
# 		--wait
# .PHONY: helm-upgrade-pro

# ## Preview helm upgrade for development (dry-run)
# helm-upgrade-dev-preview:
# 	helm upgrade $(HELM_RELEASE_NAME)-dev $(HELM_CHART_DIR)/$(HELM_CHART_NAME) \
# 		--namespace=$(NAMESPACE) \
# 		--values=$(HELM_CHART_DIR)/$(HELM_CHART_NAME)/values-dev.yaml \
# 		--set image.tag=$(IMAGE_TAG) \
# 		--dry-run
# .PHONY: helm-upgrade-dev-preview

# ## Uninstall helm release from development
# helm-uninstall-dev:
# 	helm uninstall $(HELM_RELEASE_NAME)-dev --namespace=$(NAMESPACE) --timeout=$(HELM_TIMEOUT)
# .PHONY: helm-uninstall-dev

# ## Uninstall helm release from staging
# helm-uninstall-stage:
# 	helm uninstall $(HELM_RELEASE_NAME)-stage --namespace=$(NAMESPACE) --timeout=$(HELM_TIMEOUT)
# .PHONY: helm-uninstall-stage

# ## Uninstall helm release from production
# helm-uninstall-prod:
# 	helm uninstall $(HELM_RELEASE_NAME)-prod --namespace=$(NAMESPACE) --timeout=$(HELM_TIMEOUT)
# .PHONY: helm-uninstall-prod

# ## Uninstall all helm releases
# helm-uninstall-all:
# 	helm uninstall $(HELM_RELEASE_NAME)-dev --namespace=$(NAMESPACE) --ignore-not-found || true
# 	helm uninstall $(HELM_RELEASE_NAME)-stage --namespace=$(NAMESPACE) --ignore-not-found || true
# 	helm uninstall $(HELM_RELEASE_NAME)-prod --namespace=$(NAMESPACE) --ignore-not-found || true
# .PHONY: helm-uninstall-all

# ## Test development helm release
# helm-test-dev:
# 	helm test $(HELM_RELEASE_NAME)-dev --namespace=$(NAMESPACE) --timeout=$(HELM_TIMEOUT)
# .PHONY: helm-test-dev

# ## Test staging helm release
# helm-test-stage:
# 	helm test $(HELM_RELEASE_NAME)-stage --namespace=$(NAMESPACE) --timeout=$(HELM_TIMEOUT)
# .PHONY: helm-test-stage

# ## Test production helm release
# helm-test-prod:
# 	helm test $(HELM_RELEASE_NAME)-prod --namespace=$(NAMESPACE) --timeout=$(HELM_TIMEOUT)
# .PHONY: helm-test-prod

# ## Workflow setup for development with helm
# helm-workflow-dev:
# 	helm-dependency-update
# 	helm-install-dev
# .PHONY: helm-workflow-dev

# ## Workflow setup for staging with helm
# helm-workflow-stage:
# 	helm-dependency-update
# 	helm-install-stage
# .PHONY: helm-workflow-stage

# ## Workflow setup for production with helm
# helm-workflow-prod:
# 	helm-dependency-update
# 	helm-install-prod
# .PHONY: helm-workflow-prod
