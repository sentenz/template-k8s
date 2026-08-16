# SPDX-License-Identifier: Apache-2.0

# Load Dotenv Files

DOTENV_FILES := $(filter-out %.enc,$(wildcard .env .env.*))
ifneq ($(strip $(DOTENV_FILES)),)
	include $(DOTENV_FILES)
	export
endif

# Define Variables

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:

HELM_RELEASE_NAME ?= mychart
HELM_VENDOR_DIR ?= vendor/helm
HELM_CHART_DIR ?=
HELM_CHART_NAME ?=
HELM_CHART_VERSION ?=
HELM_CHART_REPO ?=
HELM_VALUES_FILE ?= values.yaml
K8S_IMAGE_TAG ?= latest
K8S_NAMESPACE ?= default
K8S_ENV ?= dev
K8S_ENV := $(strip $(K8S_ENV))
K8S_CLUSTER_DIR ?= clusters
K8S_CLUSTER_PATH ?= $(K8S_CLUSTER_DIR)/$(K8S_ENV)
K8S_KUBECONFIG_DIR ?= .local/kubeconfig
K8S_KUBECONFIG ?= $(K8S_KUBECONFIG_DIR)/$(K8S_ENV).yaml
K8S_RENDER_FILE ?= render/kustomize/$(K8S_ENV).yaml
KIND_CLUSTER_NAME ?= template-k8s
KIND_CONFIG ?= $(K8S_CLUSTER_PATH)/kind-cluster.yaml

# ─── General ─────────────────────────────────────────────────────────────────────────────────────

default: help

# NOTE Targets MUST have a leading comment line starting with `##` to be included in the list. See the targets below for examples.
#
## Display help message with available tasks and descriptions
help:
	@awk 'BEGIN {printf "Tasks\n\tA collection of tasks used in the current project.\n\n"}'
	@awk 'BEGIN {printf "Usage\n\tmake $(shell tput -Txterm setaf 6)<task>$(shell tput -Txterm sgr0)\n\n"}' $(MAKEFILE_LIST)
	@awk '/^##/{c=substr($$0,3);next}c&&/^[[:alpha:]][[:alnum:]_-]+:/{print "$(shell tput -Txterm setaf 6)\t" substr($$1,1,index($$1,":")) "$(shell tput -Txterm sgr0)",c}1{c=0}' $(MAKEFILE_LIST) | column -s: -t
.PHONY: help

# ─── Setup & Teardown ─────────────────────────────────────────────────────────────────────────────

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

# ─── Git Hooks Manager ────────────────────────────────────────────────────────────────────────────

## Initialize Lefthook Git hooks in the local repository
githooks-lefthook-initialize:
	lefthook install --force
.PHONY: githooks-lefthook-initialize

## Deinitialize Lefthook Git hooks from the local repository
githooks-lefthook-deinitialize:
	lefthook uninstall
.PHONY: githooks-lefthook-deinitialize

# ─── Skills Manager ───────────────────────────────────────────────────────────────────────────────

## Provision new Agent Skills into the project environment
skills-agent-add:
	DISABLE_TELEMETRY=1 skills add git@gitlab.samscm.net:development-environment/templates/skills.git
.PHONY: skills-agent-add

## Synchronize and update existing Agent Skills in the project environment
skills-agent-update:
	DISABLE_TELEMETRY=1 skills update git@gitlab.samscm.net:development-environment/templates/skills.git
.PHONY: skills-agent-update

# ─── Kubernetes Manager ───────────────────────────────────────────────────────────────────────────

# K8S_KIND_IMAGE ?= $(notdir $(shell git rev-parse --show-toplevel 2>/dev/null)):$(or $(shell git tag --sort=-creatordate | head -n 1),latest)
K8S_KIND_IMAGE ?= ghcr.io/sentenz/k8s:2.1.11@sha256:31c0dd210ecdea934b7394656539d155fddf0c6627af522d307df8d18e52f71e

# Validate the selected cluster composition before Kubernetes operations
k8s-validate:
	@if [[ ! -f "$(K8S_CLUSTER_PATH)/kustomization.yaml" ]]; then \
		echo "error: Kubernetes cluster composition not found: $(K8S_CLUSTER_PATH)/kustomization.yaml" >&2; \
		exit 1; \
	fi
.PHONY: k8s-validate

## Setup the selected local Kubernetes cluster using Kind
k8s-setup: k8s-validate
	@if [[ ! -f "$(KIND_CONFIG)" ]]; then \
		echo "error: Kind cluster configuration not found for '$(K8S_ENV)': $(KIND_CONFIG)" >&2; \
		exit 1; \
	fi

	@mkdir -p "$(dir $(K8S_KUBECONFIG))"
	@if [[ ! -e "$(K8S_KUBECONFIG)" ]]; then \
		install -m 0644 /dev/null "$(K8S_KUBECONFIG)"; \
	fi

	docker run --rm --user root --network host --volume /var/run/docker.sock:/var/run/docker.sock --volume "$(CURDIR):/workspace" --workdir /workspace \
		"$(K8S_KIND_IMAGE)" kind create cluster --name "$(KIND_CLUSTER_NAME)" --config "$(KIND_CONFIG)" --kubeconfig "$(K8S_KUBECONFIG)" --wait 5m
.PHONY: k8s-setup

## Tear down the selected local Kubernetes Kind cluster
k8s-teardown:
	docker run --rm --user root --network host --volume /var/run/docker.sock:/var/run/docker.sock \
		"$(K8S_KIND_IMAGE)" kind delete cluster --name "$(KIND_CLUSTER_NAME)"

	@rm -f "$(K8S_KUBECONFIG)"
.PHONY: k8s-teardown

K8S_TOOLS_IMAGE ?= alpine/k8s:1.36.2@sha256:44ef4942e171939b9c665a4a84beb80e2dcdb9a24330d4651cfdfd2e9deecc47
K8S_TOOLS_ALIAS := docker run --rm --network host --volume "$(CURDIR):/workspace" --workdir /workspace "$(K8S_TOOLS_IMAGE)"

# Interactive user confirmation before proceeding with Kubernetes Deploy & Destroy
k8s-confirm:
	@echo ""
	@read -r -p "Confirm: Proceed with Kubernetes environment '$(K8S_ENV)' from '$(K8S_CLUSTER_PATH)'? [yes-$(K8S_ENV) / no] " confirm; \
		if [[ "$$confirm" != "yes-$(K8S_ENV)" ]]; then \
			echo "Aborted."; \
			exit 1; \
		fi
.PHONY: k8s-confirm

## Render the selected Kubernetes cluster composition
k8s-render: k8s-validate
	@mkdir -p "$(dir $(K8S_RENDER_FILE))"
	@$(K8S_TOOLS_ALIAS) kustomize build "$(K8S_CLUSTER_PATH)" --enable-helm --load-restrictor=LoadRestrictionsNone > "$(K8S_RENDER_FILE)"
.PHONY: k8s-render

## Deploy the selected Kubernetes cluster composition
k8s-deploy: k8s-validate k8s-confirm
	@$(K8S_TOOLS_ALIAS) kustomize build "$(K8S_CLUSTER_PATH)" --enable-helm --load-restrictor=LoadRestrictionsNone \
		| kubectl apply --kubeconfig "$(K8S_KUBECONFIG)" -f -
.PHONY: k8s-deploy

## Destroy the selected Kubernetes cluster composition
k8s-destroy: k8s-validate k8s-confirm
	@$(K8S_TOOLS_ALIAS) kustomize build "$(K8S_CLUSTER_PATH)" --enable-helm --load-restrictor=LoadRestrictionsNone \
		| kubectl delete --kubeconfig "$(K8S_KUBECONFIG)" -f -
.PHONY: k8s-destroy

# Observe all services across all namespaces
k8s-observability-service:
	$(K8S_TOOLS_ALIAS) kubectl get services --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-observability-service

# Observe all namespaces
k8s-observability-namespace:
	$(K8S_TOOLS_ALIAS) kubectl get namespaces --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-observability-namespace

# Observe all pods across all namespaces
k8s-observability-pod:
	$(K8S_TOOLS_ALIAS) kubectl get pods -A --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-observability-pod

# Observe all ingress controllers across all namespaces
k8s-observability-controller:
	$(K8S_TOOLS_ALIAS) kubectl get ingressclass --kubeconfig $(K8S_KUBECONFIG)
.PHONY: k8s-observability-controller

## Aggregate Kubernetes observability for services, namespaces, ingress controllers, and pods
k8s-observability:
	@echo "──── K8s Services ────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-observability-service
	@echo "──── K8s Namespaces ──────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-observability-namespace
	@echo "──── K8s Ingress Controllers ─────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-observability-controller
	@echo "──── K8s Pods ────────────────────────────────────────────────────────────────────────────"
	@$(MAKE) -s k8s-observability-pod
.PHONY: k8s-observability

# ─── Helm Charts ──────────────────────────────────────────────────────────────────────────────────

K8S_HELM_IMAGE ?= alpine/helm:4.2.3@sha256:b97ba4f9b27fe7af16ee3d37e6815783c9d4a51289b6240a9024ec471611ae9b
K8S_HELM_ALIAS := docker run --rm -v "$(CURDIR):/workspace" -w /workspace "$(K8S_HELM_IMAGE)"
HELM_DEPENDENCY_TRACK_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/dependency-track-*/dependency-track))
HELM_POSTGRESQL_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/postgresql-*/postgresql))
HELM_TRAEFIK_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/traefik-*/traefik))

## Vendor a Helm chart into Kustomize-compatible local storage
helm-vendor:
	@if [[ -z "$(HELM_CHART_NAME)" || -z "$(HELM_CHART_VERSION)" || -z "$(HELM_CHART_REPO)" ]]; then \
		echo "usage: make helm-vendor HELM_CHART_NAME=<name> HELM_CHART_VERSION=<version> HELM_CHART_REPO=<repo>" >&2; \
		exit 1; \
	fi
	@if ! [[ "$(HELM_CHART_NAME)" =~ ^[A-Za-z0-9._-]+$$ ]]; then \
		echo "error: invalid HELM_CHART_NAME '$(HELM_CHART_NAME)'" >&2; \
		exit 1; \
	fi
	@mkdir -p "$(HELM_VENDOR_DIR)"
	@rm -rf "$(HELM_VENDOR_DIR)/$(HELM_CHART_NAME)-"*
	@target="$(HELM_VENDOR_DIR)/$(HELM_CHART_NAME)-$(HELM_CHART_VERSION)"; \
		mkdir -p "$$target"; \
		$(K8S_HELM_ALIAS) pull "$(HELM_CHART_NAME)" \
			--repo "$(HELM_CHART_REPO)" \
			--version "$(HELM_CHART_VERSION)" \
			--untar \
			--untardir "$$target"
.PHONY: helm-vendor

# Render Helm charts templates with specified parameters
helm-render:
	@if [[ -z "$(HELM_CHART_DIR)" || ! -d "$(HELM_CHART_DIR)" ]]; then \
		echo "error: HELM_CHART_DIR must reference a vendored chart directory" >&2; \
		exit 1; \
	fi
	@if [[ ! -f "$(HELM_VALUES_FILE)" ]]; then \
		echo "error: Helm values file not found: $(HELM_VALUES_FILE)" >&2; \
		exit 1; \
	fi
	$(K8S_HELM_ALIAS) template \
		$(HELM_RELEASE_NAME) \
		$(HELM_CHART_DIR) \
		--namespace=$(K8S_NAMESPACE) \
		--values=$(HELM_VALUES_FILE) \
		--set image.tag=$(K8S_IMAGE_TAG) \
		--output-dir=./render/charts
.PHONY: helm-render

# Render vendored Helm chart for Dependency-Track
helm-render-dependency-track:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=dependency-track \
		HELM_CHART_DIR="$(HELM_DEPENDENCY_TRACK_CHART_DIR)" \
		HELM_VALUES_FILE="$(HELM_DEPENDENCY_TRACK_CHART_DIR)/values.yaml" \
		K8S_NAMESPACE=default \
		K8S_IMAGE_TAG="v1.0.0"
.PHONY: helm-render-dependency-track

# Render vendored Helm chart for Traefik
helm-render-traefik:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=traefik \
		HELM_CHART_DIR="$(HELM_TRAEFIK_CHART_DIR)" \
		HELM_VALUES_FILE="$(HELM_TRAEFIK_CHART_DIR)/values.yaml" \
		K8S_NAMESPACE=default \
		K8S_IMAGE_TAG="v3.0.0"
.PHONY: helm-render-traefik

# Render vendored Helm chart for PostgreSQL
helm-render-postgresql:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=postgresql \
		HELM_CHART_DIR="$(HELM_POSTGRESQL_CHART_DIR)" \
		HELM_VALUES_FILE="$(HELM_POSTGRESQL_CHART_DIR)/values.yaml" \
		K8S_NAMESPACE=default \
		K8S_IMAGE_TAG="v16.0.0"
.PHONY: helm-render-postgresql

## Render all vendored Helm charts
helm-render-charts:
	@$(MAKE) -s helm-render-dependency-track
	@$(MAKE) -s helm-render-traefik
	@$(MAKE) -s helm-render-postgresql
.PHONY: helm-render-charts

# ─── Dependency Manager ───────────────────────────────────────────────────────────────────────────

DEPENDENCY_RENOVATE_IMAGE ?= docker.io/renovate/renovate:44.28.0@sha256:11819ff9d07d24fb71695c27e27b8bd65f55d5e2134c6e01ae7392739212d6bc
DEPENDENCY_RENOVATE_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace -e LOG_LEVEL=debug -e RENOVATE_REPOSITORIES -e RENOVATE_TOKEN=$(RENOVATE_TOKEN) "$(DEPENDENCY_RENOVATE_IMAGE)"

## Update project dependencies locally using Renovate and generate a report
dependency-renovate-update:
	@mkdir -p logs/dependency

	$(DEPENDENCY_RENOVATE_ALIAS) renovate --platform=local --repository-cache=reset > logs/dependency/renovate.log 2>&1
.PHONY: dependency-renovate-update

# ─── Secrets Manager ──────────────────────────────────────────────────────────────────────────────

SECRETS_SOPS_IMAGE ?= ghcr.io/getsops/sops:v3.13.3@sha256:857f5a151ac0b2bfc55c1e4e5581d66fb8e268e4d106b38e74191f3bac9d58ea
SECRETS_SOPS_ALIAS ?= docker run --rm -v "${PWD}:/workspace" -v "$${HOME}/.gnupg:/root/.gnupg" -w /workspace "$(SECRETS_SOPS_IMAGE)"
SECRETS_SOPS_UID ?= sops-k8s

# Usage: make secrets-gpg-generate SECRETS_SOPS_UID=<uid>
#
## Generate a new GPG key pair for SOPS with the specified UID
secrets-gpg-generate:
	@gpg --batch --quiet --passphrase '' --quick-generate-key "$(SECRETS_SOPS_UID)" ed25519 cert,sign 0
	@NEW_FPR="$$(gpg --list-keys --with-colons "$(SECRETS_SOPS_UID)" | awk -F: '/^fpr:/ {print $$10; exit}')"
	@gpg --batch --quiet --passphrase '' --quick-add-key "$${NEW_FPR}" cv25519 encrypt 0
.PHONY: secrets-gpg-generate

# Usage: make secrets-gpg-export SECRETS_SOPS_UID=<uid>
#
## Export the GPG key pair for SOPS with the specified UID to ASCII files
secrets-gpg-export:
	@if [ -z "$(SECRETS_SOPS_UID)" ]; then \
		echo "usage: make secrets-gpg-export SECRETS_SOPS_UID=<uid>" >&2; \
		exit 1; \
	fi

	@gpg --armor --export "$(SECRETS_SOPS_UID)" > "$(SECRETS_SOPS_UID)-public.asc"
	@gpg --armor --export-secret-keys "$(SECRETS_SOPS_UID)" > "$(SECRETS_SOPS_UID)-private.asc"
.PHONY: secrets-gpg-export

# Usage: make secrets-gpg-import [SECRETS_SOPS_UID=<uid>] <key-files>
#
## Import GPG keys from specified files and if provided set ultimate trust for the SOPS UID
secrets-gpg-import:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-gpg-import <files>" >&2; \
		exit 1; \
	fi

	# Import keys from specified files
	@for file in $(filter-out $@,$(MAKECMDGOALS)); do \
		if [ -f "$$file" ]; then \
			gpg --import "$$file"; \
		fi; \
	done

	# Set ultimate trust for the SECRETS_SOPS_UID
	@if [ "$(origin SECRETS_SOPS_UID)" = "command line" ] && [ -n "$(SECRETS_SOPS_UID)" ]; then \
		FPR="$$( { gpg --list-keys --with-colons "$(SECRETS_SOPS_UID)" 2>/dev/null || true; } | awk -F: '/^fpr:/ {print $$10; exit}')"; \
		if [ -n "$${FPR}" ]; then \
			echo "$${FPR}:6:" | gpg --import-ownertrust; \
		fi; \
	fi
.PHONY: secrets-gpg-import

# Usage: make secrets-gpg-remove SECRETS_SOPS_UID=<uid>
#
## Remove GPG keys for SOPS with the specified UID (interactive)
secrets-gpg-remove:
	@if ! gpg --list-keys "$(SECRETS_SOPS_UID)" >/dev/null 2>&1; then
		echo "warning: no key found for '$(SECRETS_SOPS_UID)'" >&2
		exit 0
	fi

	# Delete private key first, then public key
	@gpg --yes --delete-secret-keys "$(SECRETS_SOPS_UID)"
	@gpg --yes --delete-keys "$(SECRETS_SOPS_UID)"
.PHONY: secrets-gpg-remove

# Usage: make secrets-gpg-show [SECRETS_SOPS_UID=<uid>]
#
## Show GPG public key information for SOPS UID or list all keys if UID is not set
secrets-gpg-show:
	@if [ "$(origin SECRETS_SOPS_UID)" != "command line" ]; then \
		gpg --list-keys --keyid-format long; \
		exit 0; \
	fi

	@FPR="$$( { gpg --list-keys --with-colons "$(SECRETS_SOPS_UID)" 2>/dev/null || true; } | awk -F: '/^fpr:/ {print $$10; exit}')"; \
	if [ -z "$${FPR}" ]; then \
		echo "error: no fingerprint found for UID '$(SECRETS_SOPS_UID)'" >&2; \
		exit 1; \
	fi; \
	echo -e "UID: $(SECRETS_SOPS_UID)\nFingerprint: $${FPR}"
.PHONY: secrets-gpg-show

# Usage: make secrets-sops-encrypt <files>
#
## Encrypt specified files using SOPS with GPG keys, writing output to <file>.enc
secrets-sops-encrypt:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-sops-encrypt <files>" >&2; \
		exit 1; \
	fi

	@for file in $(filter-out $@,$(MAKECMDGOALS)); do \
		if [ -f "$$file" ]; then \
			$(SECRETS_SOPS_ALIAS) encrypt --output "$$file.enc" "$$file"; \
		else \
			echo "file not found: $$file" >&2; \
		fi; \
	done
.PHONY: secrets-sops-encrypt

# Usage: make secrets-sops-decrypt <files>
#
## Decrypt specified SOPS-encrypted files (expects <file>.enc), writing output to <file>
secrets-sops-decrypt:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-sops-decrypt <files>" >&2; \
		exit 1; \
	fi

	@for file in $(filter-out $@,$(MAKECMDGOALS)); do \
		case "$$file" in \
			*.enc) \
				$(SECRETS_SOPS_ALIAS) decrypt --filename-override "$${file%.enc}" --output "$${file%.enc}" "$$file"; \
				;;
			*) \
				$(SECRETS_SOPS_ALIAS) decrypt --in-place "$$file"; \
				;;
		esac; \
	done
.PHONY: secrets-sops-decrypt

# Usage: make secrets-sops-view <file>
#
## View decrypted contents of a SOPS-encrypted file using GPG keys
secrets-sops-view:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make secrets-sops-view <file>" >&2; \
		exit 1; \
	fi

	$(SECRETS_SOPS_ALIAS) decrypt "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: secrets-sops-view

# ─── Policy Manager ───────────────────────────────────────────────────────────────────────────────

POLICY_CONFTEST_IMAGE ?= docker.io/openpolicyagent/conftest:v0.69.0@sha256:a38ba21668929a00dce2fe6ee43d1312228340bce5fd243f47dd0ce90516e558
POLICY_CONFTEST_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace "$(POLICY_CONFTEST_IMAGE)"

# Usage: make policy-conftest-test <filepath>
#
## Run Conftest container in REPL (Read-Eval-Print-Loop) to evaluate policies against input data and generate a report
policy-conftest-test:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make policy-conftest-test <filepath>"; \
		exit 1; \
	fi

	@mkdir -p logs/policy

	$(POLICY_CONFTEST_ALIAS) test "$(filter-out $@,$(MAKECMDGOALS))" > logs/policy/conftest-report.json 2>&1
.PHONY: policy-conftest-test

POLICY_REGAL_IMAGE ?= ghcr.io/open-policy-agent/regal:0.42.0@sha256:07984036043f772a1f921bd0ad9045b8bd9dc58460a1d76f476c458dc8a98b16
POLICY_REGAL_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace "$(POLICY_REGAL_IMAGE)"

# Usage: make policy-regal-lint <filepath>
#
## Lint Rego policies using Regal and generate a report
policy-regal-lint:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make policy-regal-lint <filepath>"; \
		exit 1; \
	fi

	@mkdir -p logs/policy

	$(POLICY_REGAL_ALIAS) lint "$(filter-out $@,$(MAKECMDGOALS))" --format json > logs/policy/regal.json 2>&1
.PHONY: policy-regal-lint

# ─── SAST Manager ─────────────────────────────────────────────────────────────────────────────────

SAST_SEMGREP_IMAGE ?= semgrep/semgrep:1.172.0@sha256:65dcd4408adda7c183a6b4550cb1e9b19f7f627a6fbb7e0559bd466bedc44d7b
SAST_SEMGREP_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_SEMGREP_IMAGE)"
SAST_SEMGREP_FILES ?= .
SAST_SEMGREP_FILTER = $(if $(strip $(SAST_SEMGREP_FILES)),$(SAST_SEMGREP_FILES),.)

## Scan source code for security issues using Semgrep and generate a report
sast-semgrep-scan:
	@mkdir -p logs/sast

	$(SAST_SEMGREP_ALIAS) semgrep scan --config auto --error --json --output logs/sast/semgrep.json $(SAST_SEMGREP_FILTER) 2> logs/sast/semgrep.log
.PHONY: sast-semgrep-scan

SAST_TRIVY_IMAGE ?= aquasec/trivy:0.73.0@sha256:7cced7cae583819fc7806d4cbc0dbbc7cad18b99f7d3e235192e6da8c091045c
SAST_TRIVY_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_TRIVY_IMAGE)"
SAST_TRIVY_FILES ?= .

## Scan Infrastructure-as-Code (IaC) files for misconfigurations using Trivy and generate a report
sast-trivy-misconfig:
	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) config --output logs/sast/trivy-misconfig.json $(SAST_TRIVY_FILES) 2>&1
.PHONY: sast-trivy-misconfig

## Scan local filesystem for vulnerabilities and misconfigurations using Trivy
sast-trivy-fs:
	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) filesystem --output logs/sast/trivy-filesystem.json /workspace 2>&1
.PHONY: sast-trivy-fs

# Usage: make sast-trivy-image <image_name>
#
## Scan a container image for vulnerabilities using Trivy
sast-trivy-image:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-image <image_name>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/workspace" -w /workspace "$(SAST_TRIVY_IMAGE)" image --output logs/sast/trivy-image.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-image

# Usage: make sast-trivy-image-license <image_name>
#
## Scan a container image for license compliance using Trivy
sast-trivy-image-license:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-image-license <image_name>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) image --scanners license --format table --output logs/sast/trivy-image-license.txt "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-image-license

# Usage: make sast-trivy-repository <repo_url>
#
## Scan a remote repository for vulnerabilities using Trivy
sast-trivy-repository:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-repository <repo_url>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) repository --output logs/sast/trivy-repository.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-repository

# Usage: make sast-trivy-rootfs <path>
#
## Scan a rootfs e.g. `/` for vulnerabilities using Trivy
sast-trivy-rootfs:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-rootfs <path>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) rootfs --output logs/sast/trivy-rootfs.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-rootfs

# Usage: make sast-trivy-sbom-scan <sbom_path>
#
## Scan SBOM for vulnerabilities using Trivy
sast-trivy-sbom-scan:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-scan <sbom_path>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) sbom --output logs/sast/trivy-sbom.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-scan

# Usage: make sast-trivy-sbom-cyclonedx-image <image_name>
#
## Generate SBOM in CycloneDX format for a container image using Trivy
sast-trivy-sbom-cyclonedx-image:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-cyclonedx-image <image_name>"; \
		exit 1; \
	fi

	@mkdir -p logs/sbom

	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/workspace" -w /workspace "$(SAST_TRIVY_IMAGE)" image --format cyclonedx --output logs/sbom/sbom-image.cdx.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-cyclonedx-image

# Usage: make sast-trivy-sbom-cyclonedx-fs <path>
#
## Generate SBOM in CycloneDX format for a file system using Trivy
sast-trivy-sbom-cyclonedx-fs:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-cyclonedx-fs <path>"; \
		exit 1; \
	fi

	@mkdir -p logs/sbom

	$(SAST_TRIVY_ALIAS) filesystem --format cyclonedx --output logs/sbom/sbom-fs.cdx.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-cyclonedx-fs

# Usage: make sast-trivy-sbom-license <sbom_path>
#
## Scan SBOM for license compliance using Trivy
sast-trivy-sbom-license:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-license <sbom_path>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) sbom --scanners license --format table --output logs/sast/trivy-sbom-license.txt "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-sbom-license

# Usage: make sast-trivy-sbom-attestation <intoto_sbom_path>
#
## Scan the verified SBOM attestation using Trivy
sast-trivy-sbom-attestation:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-sbom-attestation <intoto_sbom_path>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) sbom "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: sast-trivy-sbom-attestation

# Usage: make sast-trivy-vm <vm_image_path>
#
## [EXPERIMENTAL] Scan a virtual machine image using Trivy
sast-trivy-vm:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-trivy-vm <vm_image_path>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_TRIVY_ALIAS) vm --output logs/sast/trivy-vm.json "$(filter-out $@,$(MAKECMDGOALS))" 2>&1
.PHONY: sast-trivy-vm

# Usage: make sast-trivy-kubernetes [target]
#
## [EXPERIMENTAL] Scan kubernetes cluster using Trivy (default `cluster`)
sast-trivy-kubernetes:
	@echo "Note: This requires KUBECONFIG to be mounted or available to the container. Assuming ~/.kube/config is mounted to /root/.kube/config"

	@mkdir -p logs/sast

	docker run --rm -v "${HOME}/.kube/config:/root/.kube/config" -v "${PWD}:/workspace" -w /workspace "$(SAST_TRIVY_IMAGE)" kubernetes --output logs/sast/trivy-kubernetes.json $(if $(filter-out $@,$(MAKECMDGOALS)),$(filter-out $@,$(MAKECMDGOALS)),cluster) 2>&1
.PHONY: sast-trivy-kubernetes

SAST_IMAGE_GITLEAKS ?= ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f

## Scan git repository history for leaked secrets using Gitleaks and generate a report
sast-gitleaks-detect:
	@mkdir -p logs/sast

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_GITLEAKS)" detect --redact --source /workspace --report-format json --report-path logs/sast/gitleaks-detect.json 2>&1
.PHONY: sast-gitleaks-detect

## Scan staged git changes for leaked secrets using Gitleaks and generate a report
sast-gitleaks-staged:
	@mkdir -p logs/sast

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_GITLEAKS)" protect --redact --staged --source /workspace --report-format json --report-path logs/sast/gitleaks-protect.json 2>&1
.PHONY: sast-gitleaks-staged

SAST_IMAGE_TRUFFLEHOG ?= trufflesecurity/trufflehog:3.96.0@sha256:aa821cf4ace8861c7d096d83818cdf7bb9719028a52d37a52eaad44086a52577

## Scan local filesystem for leaked secrets using TruffleHog and generate a report
sast-trufflehog-fs:
	@mkdir -p logs/sast

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRUFFLEHOG)" filesystem . --no-update --json > logs/sast/trufflehog-filesystem.json 2> logs/sast/trufflehog-filesystem.log
.PHONY: sast-trufflehog-fs

## Scan git repository history for leaked secrets using TruffleHog and generate a report
sast-trufflehog-git:
	@mkdir -p logs/sast

	docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_IMAGE_TRUFFLEHOG)" git file:///workspace --no-update --json > logs/sast/trufflehog-git.json 2> logs/sast/trufflehog-git.log
.PHONY: sast-trufflehog-git

# ─── Supply Chain Security ────────────────────────────────────────────────────────────────────────

SAST_COSIGN_IMAGE ?= cgr.dev/chainguard/cosign:3.0.0@sha256:b6bc266358e9368be1b3d01fca889b78d5ad5a47832986e14640c34a237ef638
SAST_COSIGN_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_COSIGN_IMAGE)"

## Generate Cosign key pair
sast-cosign-generate-key-pair:
	$(SAST_COSIGN_ALIAS) generate-key-pair
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

	$(SAST_COSIGN_ALIAS) attest --key cosign.key --type cyclonedx --predicate logs/sbom/sbom.cdx.json "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: sast-cosign-attest

# Usage: make sast-cosign-verify <image_name>
#
## Verify SBOM attestation for an image using Cosign
sast-cosign-verify:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sast-cosign-verify <image_name>"; \
		exit 1; \
	fi
	@if [ ! -f cosign.pub ]; then \
		echo "Error: cosign.pub not found. Run 'make sast-cosign-generate-key-pair' first."; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SAST_COSIGN_ALIAS) verify-attestation --key cosign.pub --type cyclonedx "$(filter-out $@,$(MAKECMDGOALS))" > logs/sbom/sbom.cdx.intoto.jsonl 2> logs/sast/cosign-verify.log
.PHONY: sast-cosign-verify

# ─── Container Manager ────────────────────────────────────────────────────────────────────────────

CONTAINER_DOCKER_IMAGE ?= $(notdir $(shell git rev-parse --show-toplevel 2>/dev/null))
CONTAINER_DOCKER_TAG ?= $(or $(shell git tag --sort=-creatordate | head -n 1),latest)
CONTAINER_DOCKER_CONTEXT ?= .
CONTAINER_DOCKER_FILE ?= container/k8s/Dockerfile

# Usage: make container-docker-build [CONTAINER_DOCKER_IMAGE=<name>] [CONTAINER_DOCKER_TAG=<tag>] [CONTAINER_DOCKER_FILE=<file>] [CONTAINER_DOCKER_CONTEXT=<context>]
#
## Build the Docker container image with the specified name, tag, and context
container-docker-build:
	docker build -f "$(CONTAINER_DOCKER_FILE)" -t "$(CONTAINER_DOCKER_IMAGE):$(CONTAINER_DOCKER_TAG)" "$(CONTAINER_DOCKER_CONTEXT)"
.PHONY: container-docker-build

# Usage: make container-docker-run [CONTAINER_DOCKER_IMAGE=<name>] [CONTAINER_DOCKER_TAG=<tag>]
#
## Run the Docker container image with the specified name and tag
container-docker-run:
	docker run --rm "$(CONTAINER_DOCKER_IMAGE):$(CONTAINER_DOCKER_TAG)"
.PHONY: container-docker-run

## Teardown Docker containers and remove all unused images, containers, volumes, and networks
container-docker-teardown:
	# Display Docker disk usage statistics (images, containers, networks, volumes with links and sizes)
	@docker system df -v
	# Remove all unused Docker objects (images, containers, networks)
	@docker system prune -f -a --filter "until=24h"
	# Remove all Docker volumes (unused named `LINKS = 0`, anonymous)
	@docker volume prune -f -a --filter "label!=keep=true"
.PHONY: container-docker-teardown

# ─── Certificate Manager ─────────────────────────────────────────────────────────────────────────

CERT_HOSTNAME ?=
CERT_DIR ?= $(K8S_CLUSTER_PATH)
CERT_DAYS ?= 365

# Usage: make k8s-certificate-generate CERT_HOSTNAME=<hostname-or-url> [CERT_DIR=<directory>] [CERT_DAYS=<days>]
#
## Generate a self-signed TLS certificate for a local hostname or URL
k8s-certificate-generate:
	@raw_hostname="$(strip $(CERT_HOSTNAME))"
	if [[ -z "$$raw_hostname" ]]; then
		echo "usage: make k8s-certificate-generate CERT_HOSTNAME=<hostname-or-url> [CERT_DIR=<directory>] [CERT_DAYS=<days>]" >&2
		exit 1
	fi

	hostname="$$raw_hostname"
	hostname="$${hostname#*://}"
	hostname="$${hostname%%/*}"
	hostname="$${hostname%%\?*}"
	hostname="$${hostname%%\#*}"
	hostname="$${hostname%%:*}"

	if (( $${#hostname} > 253 )) || [[ ! "$$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$$ ]] || [[ "$$hostname" == *..* ]]; then
		echo "error: invalid hostname derived from '$(CERT_HOSTNAME)': $$hostname" >&2
		exit 1
	fi
	if [[ ! "$(CERT_DAYS)" =~ ^[1-9][0-9]*$$ ]]; then
		echo "error: CERT_DAYS must be a positive integer" >&2
		exit 1
	fi
	if ! command -v openssl >/dev/null 2>&1; then
		echo "error: openssl is required to generate a self-signed certificate" >&2
		exit 1
	fi

	output_dir="$(CERT_DIR)"
	certificate_path="$$output_dir/$$hostname+1.pem"
	private_key_path="$$output_dir/$$hostname+1-key.pem"
	mkdir -p "$$output_dir"

	umask 077
	openssl req \
		-x509 \
		-nodes \
		-newkey rsa:2048 \
		-sha256 \
		-days "$(CERT_DAYS)" \
		-keyout "$$private_key_path" \
		-out "$$certificate_path" \
		-subj "/CN=$$hostname" \
		-addext "subjectAltName=DNS:$$hostname"
	chmod 0644 "$$certificate_path"

	printf 'Generated self-signed certificate for %s\n  certificate: %s\n  private key: %s\n' \
		"$$hostname" "$$certificate_path" "$$private_key_path"
.PHONY: k8s-certificate-generate
