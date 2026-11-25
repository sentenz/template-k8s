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
K8S_ENVIRONMENTS ?= $(notdir $(patsubst %/,%,$(dir $(wildcard $(K8S_CLUSTER_DIR)/*/kustomization.yaml))))
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
## Display help message with a list of available tasks and their descriptions
help:
	@awk 'BEGIN {printf "Tasks\n\tA collection of tasks used in the current project.\n\n"}'
	@awk 'BEGIN {printf "Usage\n\tmake $(shell tput -Txterm setaf 6)<task>$(shell tput -Txterm sgr0)\n\n"}' $(MAKEFILE_LIST)
	@awk '/^##/{c=substr($$0,3);next}c&&/^[[:alpha:]][[:alnum:]_-]+:/{print "$(shell tput -Txterm setaf 6)\t" substr($$1,1,index($$1,":")) "$(shell tput -Txterm sgr0)",c}1{c=0}' $(MAKEFILE_LIST) | column -s: -t
.PHONY: help

# ─── Setup & Teardown ────────────────────────────────────────────────────────────────────────────

# NOTE Privileged task may require elevated permissions (e.g., sudo) to execute.
#
## Initialize a software development workspace with requisites
bootstrap:
	cd $(@D)/scripts && ./bootstrap.sh
.PHONY: bootstrap

# NOTE Privileged task may require elevated permissions (e.g., sudo) to execute.
#
## Install and configure all dependencies essential for development
setup:
	cd $(@D)/scripts && ./setup.sh
.PHONY: setup

# NOTE Privileged task may require elevated permissions (e.g., sudo) to execute.
#
## Remove development artifacts and restore the host to its pre-setup state
teardown:
	cd $(@D)/scripts && ./teardown.sh
.PHONY: teardown

# ─── Git Hooks Manager ───────────────────────────────────────────────────────────────────────────

## Initialize Lefthook Git hooks in the local repository
githooks-lefthook-initialize:
	lefthook install --force
.PHONY: githooks-lefthook-initialize

## Deinitialize Lefthook Git hooks from the local repository
githooks-lefthook-deinitialize:
	lefthook uninstall
.PHONY: githooks-lefthook-deinitialize

# ─── Skills Manager ──────────────────────────────────────────────────────────────────────────────

## Provision new Agent Skills into the project environment
skills-agent-add:
	DISABLE_TELEMETRY=1 skills add git@gitlab.samscm.net:development-environment/templates/skills.git
.PHONY: skills-agent-add

## Synchronize and update existing Agent Skills in the project environment
skills-agent-update:
	DISABLE_TELEMETRY=1 skills update git@gitlab.samscm.net:development-environment/templates/skills.git
.PHONY: skills-agent-update

# ─── Kubernetes Manager ──────────────────────────────────────────────────────────────────────────

# K8S_KIND_IMAGE ?= $(notdir $(shell git rev-parse --show-toplevel 2>/dev/null)):$(or $(shell git tag --sort=-creatordate | head -n 1),latest)
K8S_KIND_IMAGE ?= ghcr.io/sentenz/k8s:2.1.19@sha256:ff6e15627067fc522cb2511f3216dc85bcf7839d6317229a64dec8c56baafbdd

# Validate the selected cluster composition before Kubernetes operations
k8s-validate:
	@if [[ "$(words $(K8S_ENV))" -ne 1 || -z "$(filter $(K8S_ENVIRONMENTS),$(K8S_ENV))" ]]; then \
		echo "error: K8S_ENV must be exactly one of: $(K8S_ENVIRONMENTS)" >&2; \
		exit 1; \
	fi
	@if [[ ! -f "$(K8S_CLUSTER_PATH)/kustomization.yaml" ]]; then \
		echo "error: Kubernetes cluster composition not found: $(K8S_CLUSTER_PATH)/kustomization.yaml" >&2; \
		exit 1; \
	fi
.PHONY: k8s-validate

## Bootstrap the selected local Kubernetes cluster using Kind
k8s-bootstrap: k8s-validate
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
.PHONY: k8s-bootstrap

## Tear down the selected local Kubernetes Kind cluster
k8s-teardown:
	docker run --rm --user root --network host --volume /var/run/docker.sock:/var/run/docker.sock \
		"$(K8S_KIND_IMAGE)" kind delete cluster --name "$(KIND_CLUSTER_NAME)"

	@rm -f "$(K8S_KUBECONFIG)"
.PHONY: k8s-teardown

K8S_TOOLS_IMAGE ?= alpine/k8s:1.37.2@sha256:7a82aeefea3d554a43a8676b137f2b88bae6c1fe11c13862b191b3a086cc28c0
K8S_TOOLS_ALIAS := docker run --rm --network host --volume "$(CURDIR):/workspace" --workdir /workspace "$(K8S_TOOLS_IMAGE)"

# Interactive user confirmation before proceeding with Kubernetes Deploy & Destroy
k8s-confirm:
	@read -r -p "Confirm: Proceed with Kubernetes environment '$(K8S_ENV)' from '$(K8S_CLUSTER_PATH)'? [yes-$(K8S_ENV) / no] " confirm; \
		if [[ "$$confirm" != "yes-$(K8S_ENV)" ]]; then \
			echo "Aborted."; \
			exit 1; \
		fi
.PHONY: k8s-confirm

## Render the selected Kubernetes cluster composition
k8s-render: k8s-validate
	@mkdir -p "$(dir $(K8S_RENDER_FILE))"
	@set -euo pipefail; \
	output="$$(mktemp "$(K8S_RENDER_FILE).XXXXXX")"; \
	trap 'rm -f "$$output"' EXIT HUP INT TERM; \
	$(K8S_TOOLS_ALIAS) kustomize build "$(K8S_CLUSTER_PATH)" --enable-helm --load-restrictor=LoadRestrictionsNone > "$$output"; \
	mv "$$output" "$(K8S_RENDER_FILE)"
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

# ─── Helm Charts ─────────────────────────────────────────────────────────────────────────────────

K8S_HELM_IMAGE ?= alpine/helm:4.3.2@sha256:a3b9d617c0c30a6c488cebb429c4ba83995a26dc2184599af5fd408a361b2e67
K8S_HELM_ALIAS := docker run --rm -v "$(CURDIR):/workspace" -w /workspace "$(K8S_HELM_IMAGE)"
# Extra `helm template` --set arguments. Defaults to pinning `image.tag`; charts
# that pin images by digest (e.g. the Sigstore charts) override this to empty.
HELM_SET_ARGS ?= --set image.tag=$(K8S_IMAGE_TAG)
HELM_DEPENDENCY_TRACK_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/dependency-track-*/dependency-track))
HELM_POSTGRESQL_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/postgresql-*/postgresql))
HELM_TRAEFIK_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/traefik-*/traefik))
HELM_FULCIO_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/fulcio-*/fulcio))
HELM_REKOR_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/rekor-*/rekor))
HELM_MYSQL_CHART_DIR = $(firstword $(wildcard $(HELM_VENDOR_DIR)/mysql-*/mysql))

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
		$(HELM_SET_ARGS) \
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

# Render vendored Helm chart for Fulcio
helm-render-fulcio:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=fulcio \
		HELM_CHART_DIR="$(HELM_FULCIO_CHART_DIR)" \
		HELM_VALUES_FILE="$(HELM_FULCIO_CHART_DIR)/values.yaml" \
		K8S_NAMESPACE=fulcio-system \
		HELM_SET_ARGS=""
.PHONY: helm-render-fulcio

# Render vendored Helm chart for Rekor
helm-render-rekor:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=rekor \
		HELM_CHART_DIR="$(HELM_REKOR_CHART_DIR)" \
		HELM_VALUES_FILE="$(HELM_REKOR_CHART_DIR)/values.yaml" \
		K8S_NAMESPACE=rekor-system \
		HELM_SET_ARGS=""
.PHONY: helm-render-rekor

# Render vendored Helm chart for the dedicated Sigstore MySQL instance
helm-render-mysql-sigstore:
	@$(MAKE) helm-render \
		HELM_RELEASE_NAME=mysql-sigstore \
		HELM_CHART_DIR="$(HELM_MYSQL_CHART_DIR)" \
		HELM_VALUES_FILE="$(HELM_MYSQL_CHART_DIR)/values.yaml" \
		K8S_NAMESPACE=mysql-sigstore
.PHONY: helm-render-mysql-sigstore

## Render all vendored Helm charts
helm-render-charts:
	@$(MAKE) -s helm-render-dependency-track
	@$(MAKE) -s helm-render-traefik
	@$(MAKE) -s helm-render-postgresql
	@$(MAKE) -s helm-render-fulcio
	@$(MAKE) -s helm-render-rekor
	@$(MAKE) -s helm-render-mysql-sigstore
.PHONY: helm-render-charts

# ─── Dependency Manager ──────────────────────────────────────────────────────────────────────────

DEPENDENCY_RENOVATE_IMAGE ?= docker.io/renovate/renovate:44.262.2@sha256:2d5cd4c778b9a2c36623302ceec231a813d8eed77cea19da13b73dd4e8e92e54
DEPENDENCY_RENOVATE_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace -e LOG_LEVEL=debug -e RENOVATE_REPOSITORIES -e RENOVATE_TOKEN=$(RENOVATE_TOKEN) "$(DEPENDENCY_RENOVATE_IMAGE)"

## Update project dependencies locally using Renovate and generate a report
dependency-renovate-update:
	@mkdir -p logs/dependency

	$(DEPENDENCY_RENOVATE_ALIAS) renovate --platform=local --repository-cache=reset > logs/dependency/renovate.log 2>&1
.PHONY: dependency-renovate-update

# ─── SBOM Manager ────────────────────────────────────────────────────────────────────────────────

SBOM_CONTAINER_IMAGE ?= ghcr.io/sentenz/sbom-cli:v1.0.6@sha256:6ba64640f06b7505fc4566e7ae0ae880fb727db62aa3e58ae04258f98bfc3ff0
SBOM_CONTAINER_ALIAS := docker run --rm --network=host -v "${PWD}:/workspace" -w /workspace "$(SBOM_CONTAINER_IMAGE)"

SBOM_FILE_ENV ?= .env
SBOM_FILE_CDX ?= logs/sbom/sbom-image.cdx.json

# Usage: make sbom-upload SBOM_FILE_ENV=".env.stage" SBOM_FILE_CDX="logs/sbom/sbom-image.cdx.json"
#
## Upload SBOM to the SCA platform and generate a report
sbom-upload:
	@mkdir -p logs/sbom

	$(SBOM_CONTAINER_ALIAS) --env-file "$(SBOM_FILE_ENV)" upload --file "$(SBOM_FILE_CDX)" 2>&1 | tee logs/sbom/upload.log
.PHONY: sbom-upload

# ─── Dependency-Track Manager ────────────────────────────────────────────────────────────────────

DTRACK_TOOLS_DIR ?= apps/dependency-track/tools
DTRACK_TOOLS_FILE ?= $(DTRACK_TOOLS_DIR)/portfolio-export.json
DTRACK_USERS_FILE ?= $(DTRACK_TOOLS_DIR)/users.json
DTRACK_OSV_FILE ?= $(DTRACK_TOOLS_DIR)/osv-config-export.json
DTRACK_POLICIES_FILE ?= $(DTRACK_TOOLS_DIR)/policies-export.json
DTRACK_VULN_POLICIES_FILE ?= $(DTRACK_TOOLS_DIR)/vuln-policies-export.json
DTRACK_VIOLATION_AUDIT_FILE ?= $(DTRACK_TOOLS_DIR)/violation-audit-export.json
DTRACK_NOTIFICATIONS_FILE ?= $(DTRACK_TOOLS_DIR)/notifications-export.json
DTRACK_SERVICE_ACCOUNTS_FILE ?= $(DTRACK_TOOLS_DIR)/service-accounts-export.json
DTRACK_PROJECT ?=
DTRACK_URL ?= https://dependency-track.localhost
DTRACK_TOKEN ?= odt_SbZ5Borx_MhFRguK1eTES4L7d1Tu3NQcja1r7jzSH

# Usage: make dtrack-validate DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
# Validate Dependency-Track connection variables are provided
dtrack-validate:
	@if [[ -z "$(DTRACK_URL)" ]]; then \
		echo "error: DTRACK_URL is required (e.g. https://dependency-track.localhost)" >&2; \
		exit 1; \
	fi
	@if [[ -z "$(DTRACK_TOKEN)" ]]; then \
		echo "error: DTRACK_TOKEN is required (admin API token)" >&2; \
		exit 1; \
	fi
.PHONY: dtrack-validate

# Usage: make dtrack-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the Dependency-Track portfolio (projects, teams, permissions, ACLs, tags, users) to JSON
dtrack-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-portfolio.py" --out "$(DTRACK_TOOLS_FILE)"
.PHONY: dtrack-export

# Usage: make dtrack-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview importing the Dependency-Track portfolio into the target instance (no changes)
dtrack-import-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-portfolio.py" --export "$(DTRACK_TOOLS_FILE)" --dry-run
.PHONY: dtrack-import-dry-run

# Usage: make dtrack-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Import the Dependency-Track portfolio (projects, teams, permissions, ACLs, tags) into the target instance
dtrack-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-portfolio.py" --export "$(DTRACK_TOOLS_FILE)"
.PHONY: dtrack-import

# Usage: make dtrack-import-users DTRACK_URL=<base-url> DTRACK_TOKEN=<token> DTRACK_USERS_FILE=<users-file>
#
## Import the Dependency-Track portfolio including managed users (requires DTRACK_USERS_FILE)
dtrack-import-users: dtrack-validate
	@if [[ ! -f "$(DTRACK_USERS_FILE)" ]]; then \
		echo "error: users file not found: $(DTRACK_USERS_FILE) (copy users.template.json and set passwords)" >&2; \
		exit 1; \
	fi
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-portfolio.py" --export "$(DTRACK_TOOLS_FILE)" --users "$(DTRACK_USERS_FILE)"
.PHONY: dtrack-import-users

# Usage: make dtrack-import-service-accounts DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Import the Dependency-Track portfolio including service accounts (5.2.0+).
## Re-issues one API key per service account; the plain-text key is printed once to stderr.
dtrack-import-service-accounts: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-portfolio.py" --export "$(DTRACK_TOOLS_FILE)" --service-accounts
.PHONY: dtrack-import-service-accounts

# Usage: make dtrack-create-service-accounts DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Create a service account for each automation (CI) team and issue one API key each.
## Idempotent; the plain-text key is printed once to stderr. Add --rotate to re-issue existing keys.
dtrack-create-service-accounts: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/create-service-accounts.py"
.PHONY: dtrack-create-service-accounts

# Usage: make dtrack-service-accounts-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the Dependency-Track service accounts (v2) to JSON
dtrack-service-accounts-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-service-accounts.py" --out "$(DTRACK_SERVICE_ACCOUNTS_FILE)"
.PHONY: dtrack-service-accounts-export

# Usage: make dtrack-service-accounts-dry-run DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview applying the Dependency-Track service accounts (no changes)
dtrack-service-accounts-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-service-accounts.py" --export "$(DTRACK_SERVICE_ACCOUNTS_FILE)" --dry-run
.PHONY: dtrack-service-accounts-dry-run

# Usage: make dtrack-service-accounts-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Apply the Dependency-Track service accounts (v2) to the target instance.
## Re-issues one API key per created account; the plain-text key is printed once to stderr.
dtrack-service-accounts-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-service-accounts.py" --export "$(DTRACK_SERVICE_ACCOUNTS_FILE)"
.PHONY: dtrack-service-accounts-import

# Usage: make dtrack-osv-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the OSV vulnerability data source config (ecosystems + settings) to JSON
dtrack-osv-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-osv-config.py" --out "$(DTRACK_OSV_FILE)"
.PHONY: dtrack-osv-export

# Usage: make dtrack-osv-import-dry-run DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview applying the OSV data source config to the target instance (no changes)
dtrack-osv-import-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-osv-config.py" --export "$(DTRACK_OSV_FILE)" --dry-run
.PHONY: dtrack-osv-import-dry-run

# Usage: make dtrack-osv-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Apply the OSV data source config to the target instance and trigger a mirror
dtrack-osv-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-osv-config.py" --export "$(DTRACK_OSV_FILE)" --mirror
.PHONY: dtrack-osv-import

# Usage: make dtrack-policies-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the Dependency-Track policies (e.g. CVE alarms) to JSON
dtrack-policies-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-policies.py" --out "$(DTRACK_POLICIES_FILE)"
.PHONY: dtrack-policies-export

# Usage: make dtrack-policies-dry-run DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview applying the Dependency-Track policies (e.g. CVE alarms) to the target instance (no changes)
dtrack-policies-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-policies.py" --export "$(DTRACK_POLICIES_FILE)" --dry-run
.PHONY: dtrack-policies-dry-run

# Usage: make dtrack-policies-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Apply the Dependency-Track policies (e.g. CVE alarms) to the target instance
dtrack-policies-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-policies.py" --export "$(DTRACK_POLICIES_FILE)"
.PHONY: dtrack-policies-import

# Usage: make dtrack-notifications-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the Dependency-Track notification rules to JSON
dtrack-notifications-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-notifications.py" --out "$(DTRACK_NOTIFICATIONS_FILE)"
.PHONY: dtrack-notifications-export

# Usage: make dtrack-notifications-dry-run DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview applying the Dependency-Track notification rules (no changes)
dtrack-notifications-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-notifications.py" --export "$(DTRACK_NOTIFICATIONS_FILE)" --dry-run
.PHONY: dtrack-notifications-dry-run

# Usage: make dtrack-notifications-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Apply the Dependency-Track notification rules (e.g. policy violation email alerts)
dtrack-notifications-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-notifications.py" --export "$(DTRACK_NOTIFICATIONS_FILE)"
.PHONY: dtrack-notifications-import

# ─── Vulnerability policies (v2) ─────────────────────────────────────────────────────────────────

# Usage: make dtrack-vuln-policies-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the Dependency-Track vulnerability policies (v2, CEL-based) to JSON
dtrack-vuln-policies-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-vuln-policies.py" --out "$(DTRACK_VULN_POLICIES_FILE)"
.PHONY: dtrack-vuln-policies-export

# Usage: make dtrack-vuln-policies-dry-run DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview applying the Dependency-Track vulnerability policies (no changes)
dtrack-vuln-policies-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-vuln-policies.py" --export "$(DTRACK_VULN_POLICIES_FILE)" --dry-run
.PHONY: dtrack-vuln-policies-dry-run

# Usage: make dtrack-vuln-policies-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Apply the Dependency-Track vulnerability policies (v2, CEL-based) to the target instance
dtrack-vuln-policies-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-vuln-policies.py" --export "$(DTRACK_VULN_POLICIES_FILE)"
.PHONY: dtrack-vuln-policies-import

# ─── Policy violation audit (triage) ─────────────────────────────────────────────────────────────

# Usage: make dtrack-violation-audit-export DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Export the policy-violation audit trail (analysis state, suppression, comments) to JSON
dtrack-violation-audit-export: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-violation-audit.py" --out "$(DTRACK_VIOLATION_AUDIT_FILE)"
.PHONY: dtrack-violation-audit-export

# Usage: make dtrack-violation-audit-dry-run DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Preview re-applying the recorded violation analysis decisions (no changes)
dtrack-violation-audit-dry-run: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-violation-audit.py" --export "$(DTRACK_VIOLATION_AUDIT_FILE)" --dry-run
.PHONY: dtrack-violation-audit-dry-run

# Usage: make dtrack-violation-audit-import DTRACK_URL=<base-url> DTRACK_TOKEN=<token>
#
## Re-apply the recorded violation analysis decisions (state, suppression, comments)
dtrack-violation-audit-import: dtrack-validate
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/import-violation-audit.py" --export "$(DTRACK_VIOLATION_AUDIT_FILE)"
.PHONY: dtrack-violation-audit-import

# Usage: make dtrack-project-violations DTRACK_URL=<base-url> DTRACK_TOKEN=<token> DTRACK_PROJECT=<name>
#
## Export a single project's policy violations as a JSON report (read-only)
dtrack-project-violations: dtrack-validate
	@if [[ -z "$(DTRACK_PROJECT)" ]]; then \
		echo "error: DTRACK_PROJECT is required (project name)" >&2; \
		exit 1; \
	fi
	DTRACK_URL="$(DTRACK_URL)" DTRACK_TOKEN="$(DTRACK_TOKEN)" \
		python3 "$(DTRACK_TOOLS_DIR)/export-project-violations.py" --project "$(DTRACK_PROJECT)"
.PHONY: dtrack-project-violations

# ─── Secrets Manager ─────────────────────────────────────────────────────────────────────────────

SECRETS_SOPS_IMAGE ?= ghcr.io/getsops/sops:v3.13.3@sha256:857f5a151ac0b2bfc55c1e4e5581d66fb8e268e4d106b38e74191f3bac9d58ea
SECRETS_SOPS_ALIAS ?= docker run --rm --user "$(shell id -u):$(shell id -g)" -e GNUPGHOME=/tmp/.gnupg -v "${PWD}:/workspace" -v "$${HOME}/.gnupg:/tmp/.gnupg" -w /workspace "$(SECRETS_SOPS_IMAGE)"
SECRETS_SOPS_UID ?= sops-$(notdir $(CURDIR))

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

# ─── Policy Manager ──────────────────────────────────────────────────────────────────────────────

POLICY_CONFTEST_IMAGE ?= docker.io/openpolicyagent/conftest:v0.71.1@sha256:0e77cdf7c1fcde035f3c579e4aaa6664ee2a8be5777eaa9af9f520cdd02280c0
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

POLICY_REGAL_IMAGE ?= ghcr.io/open-policy-agent/regal:0.43.0@sha256:29460f0ec1340d37f6c0c74bcbd88dd232fd8382c7a2337f0684415bd4c46da1
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

# ─── SAST Manager ────────────────────────────────────────────────────────────────────────────────

SAST_SEMGREP_IMAGE ?= semgrep/semgrep:1.186.0@sha256:6e1b04340e60e910fbb4ddbf3c857ab0918f064417ad5ac530014ccb3cf8c8f1
SAST_SEMGREP_ALIAS := docker run --rm -v "${PWD}:/workspace" -w /workspace "$(SAST_SEMGREP_IMAGE)"
SAST_SEMGREP_FILES ?= .
SAST_SEMGREP_FILTER = $(if $(strip $(SAST_SEMGREP_FILES)),$(SAST_SEMGREP_FILES),.)

## Scan source code for security issues using Semgrep and generate a report
sast-semgrep-scan:
	@mkdir -p logs/sast

	$(SAST_SEMGREP_ALIAS) semgrep scan --config auto --error --json --output logs/sast/semgrep.json $(SAST_SEMGREP_FILTER) 2> logs/sast/semgrep.log
.PHONY: sast-semgrep-scan

SAST_TRIVY_IMAGE ?= aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb
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

SAST_TRIVY_KBOM_FILE ?= logs/sbom/kbom.cdx.json

## Generate a CycloneDX KBOM (Kubernetes Bill of Materials) from the selected Kubernetes cluster
sast-trivy-kbom:
	@test -s "$(K8S_KUBECONFIG)" || { \
		echo "error: kubeconfig not found: $(K8S_KUBECONFIG)" >&2; \
		exit 1; \
	}

	@mkdir -p "$(dir $(SAST_TRIVY_KBOM_FILE))"

	docker run --rm --user root --network host --volume /var/run/docker.sock:/var/run/docker.sock --volume "$(CURDIR):/workspace" --workdir /workspace \
		"$(SAST_TRIVY_IMAGE)" k8s --kubeconfig "$(K8S_KUBECONFIG)" --format cyclonedx --output "/workspace/$(SAST_TRIVY_KBOM_FILE)"
.PHONY: sast-trivy-kbom

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

SAST_IMAGE_TRUFFLEHOG ?= trufflesecurity/trufflehog:3.100.1@sha256:9c7a8325d43a4af2960d3f21d61a08981d8a1bf0542e007efa2e47097e386452

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

# ─── Software Supply Chain Security (SSCS) ───────────────────────────────────────────────────────

SSCS_COSIGN_IMAGE ?= ghcr.io/sigstore/cosign/cosign:v3.1.5@sha256:191099139868a6cd02abae63f2919e0915dcaa7bcc22bda6fbd11fd0dd5599e7
# --network host: cosign must reach the local registry (localhost:5000) and the
# self-hosted Sigstore endpoints (fulcio.localhost / rekor.localhost) by name.
# --add-host: *.localhost does not resolve inside containers (WSL2-only DNS), so
# map the Sigstore hostnames to the local proxy that fronts the Kind cluster.
SSCS_COSIGN_ADD_HOSTS ?= --add-host fulcio.localhost:127.0.0.1 --add-host rekor.localhost:127.0.0.1
# Self-signed ingress certificates (fulcio.localhost + rekor.localhost) that cosign must trust
# to reach the self-hosted endpoints over TLS. Built from clusters/<env>/secrets/.
SSCS_COSIGN_TRUST_BUNDLE ?= logs/sast/sigstore-ingress-ca.pem
# Pass the TLS trust bundle into the cosign container (mounted at /workspace).
# Go falls back to the system roots if the file is absent, so this is safe for
# all cosign targets (key-based flows included).
SSCS_COSIGN_TLS_ENV ?= -e SSL_CERT_FILE=/workspace/$(SSCS_COSIGN_TRUST_BUNDLE)
# Run as the host user so cosign can write artifacts (signing config, bundles)
# into the workspace; the image's default nonroot user cannot.
SSCS_COSIGN_ALIAS := docker run --rm --user "$(shell id -u):$(shell id -g)" --network host $(SSCS_COSIGN_ADD_HOSTS) $(SSCS_COSIGN_TLS_ENV) -v "${PWD}:/workspace" -w /workspace "$(SSCS_COSIGN_IMAGE)"
# Self-hosted Sigstore endpoints (see infrastructure/services/sigstore).
SAST_FULCIO_URL ?= https://fulcio.localhost
SAST_REKOR_URL ?= https://rekor.localhost
# Kubernetes ServiceAccount identity for Fulcio (see infrastructure/services/sigstore/base/serviceaccount.yaml).
# Fulcio's default config trusts Kubernetes SA tokens, so a minted token is a valid signing identity.
SSCS_COSIGN_SA ?= cosign-dev
SSCS_COSIGN_SA_NAMESPACE ?= fulcio-system
# Fulcio CA chain secret (key `cert`) created by the chart's createcerts Job; used to verify signatures.
SAST_FULCIO_CA_SECRET ?= fulcio-server-secret
SAST_FULCIO_CA_NAMESPACE ?= fulcio-system
SSCS_COSIGN_CA_FILE ?= logs/sast/fulcio-ca.pem
# CT-log (ctlog) public key secret, used to build the TrustedRoot for verification.
SAST_CTLOG_PUBLIC_KEY_SECRET ?= ctlog-public-key
SAST_CTLOG_NAMESPACE ?= ctlog-system
# Sigstore TrustedRoot JSON bundling the self-hosted Fulcio CA, Rekor public key, and CT-log key.
SSCS_COSIGN_TRUSTED_ROOT ?= logs/sast/trusted-root.json
# Sigstore signing config (cosign 3.x) pointing at the self-hosted Fulcio/Rekor endpoints.
SSCS_COSIGN_SIGNING_CONFIG ?= logs/sast/signing-config.json
# Fulcio expects identity tokens minted for audience `sigstore`.
SSCS_COSIGN_AUDIENCE ?= sigstore
# The OIDC issuer this cluster mints SA tokens with (verify with
# `kubectl get --raw /.well-known/openid-configuration`).
SSCS_COSIGN_OIDC_ISSUER ?= https://kubernetes.default.svc.cluster.local
# The Fulcio certificate identity for the signing ServiceAccount, asserted at verify time.
SSCS_COSIGN_IDENTITY = https://kubernetes.io/namespaces/$(SSCS_COSIGN_SA_NAMESPACE)/serviceaccounts/$(SSCS_COSIGN_SA)

## Generate Cosign key pair
sscs-cosign-generate-key-pair:
	$(SSCS_COSIGN_ALIAS) generate-key-pair
.PHONY: sscs-cosign-generate-key-pair

# Usage: make sscs-cosign-attest <image_name>
#
## Attest an image with the generated SBOM using Cosign
sscs-cosign-attest:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sscs-cosign-attest <image_name>"; \
		exit 1; \
	fi
	@if [ ! -f cosign.key ]; then \
		echo "Error: cosign.key not found. Run 'make sscs-cosign-generate-key-pair' first."; \
		exit 1; \
	fi
	@if [ ! -f logs/sbom/sbom.cdx.json ]; then \
		echo "Error: logs/sbom/sbom.cdx.json not found. Run 'make sast-trivy-sbom-cyclonedx <image_name>' first."; \
		exit 1; \
	fi

	$(SSCS_COSIGN_ALIAS) attest --key cosign.key --type cyclonedx --predicate logs/sbom/sbom.cdx.json "$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: sscs-cosign-attest

# Usage: make sscs-cosign-verify <image_name>
#
## Verify SBOM attestation for an image using Cosign
sscs-cosign-verify:
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sscs-cosign-verify <image_name>"; \
		exit 1; \
	fi
	@if [ ! -f cosign.pub ]; then \
		echo "Error: cosign.pub not found. Run 'make sscs-cosign-generate-key-pair' first."; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SSCS_COSIGN_ALIAS) verify-attestation --key cosign.pub --type cyclonedx "$(filter-out $@,$(MAKECMDGOALS))" > logs/sbom/sbom.cdx.intoto.jsonl 2> logs/sast/cosign-verify.log
.PHONY: sscs-cosign-verify

# Usage: make sscs-cosign-token [SSCS_COSIGN_SA=<sa>] [SSCS_COSIGN_SA_NAMESPACE=<ns>]
#
## Mint a short-lived OIDC token for the Kubernetes ServiceAccount identity (default 1h)
sscs-cosign-token:
	@kubectl --kubeconfig "$(K8S_KUBECONFIG)" create token "$(SSCS_COSIGN_SA)" -n "$(SSCS_COSIGN_SA_NAMESPACE)" --audience="$(SSCS_COSIGN_AUDIENCE)"
.PHONY: sscs-cosign-token

# Usage: make sscs-cosign-trust-bundle
#
## Build the TLS trust bundle (self-signed fulcio.localhost + rekor.localhost certs)
## that cosign uses to reach the self-hosted endpoints over TLS. Requires the
## SOPS-decrypted certs under clusters/<env>/secrets/ (run secrets-sops-decrypt first).
sscs-cosign-trust-bundle:
	@mkdir -p "$(dir $(SSCS_COSIGN_TRUST_BUNDLE))"
	@cat "$(K8S_CLUSTER_PATH)/secrets/fulcio.localhost+1.pem" "$(K8S_CLUSTER_PATH)/secrets/rekor.localhost+1.pem" > "$(SSCS_COSIGN_TRUST_BUNDLE)"
.PHONY: sscs-cosign-trust-bundle

# Usage: make sscs-cosign-trusted-root
#
## Build a Sigstore TrustedRoot JSON for the self-hosted Sigstore stack, bundling
## the Fulcio CA, the Rekor public key, and the CT-log (ctlog) public key. cosign
## 3.x verify requires this (the new bundle format rejects --certificate-chain).
sscs-cosign-trusted-root:
	@mkdir -p "$(dir $(SSCS_COSIGN_TRUSTED_ROOT))"
	@tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT
	kubectl --kubeconfig "$(K8S_KUBECONFIG)" get secret "$(SAST_FULCIO_CA_SECRET)" -n "$(SAST_FULCIO_CA_NAMESPACE)" -o jsonpath='{.data.cert}' | base64 -d > "$$tmp/fulcio.pem"
	openssl x509 -in "$$tmp/fulcio.pem" -outform DER | base64 -w0 > "$$tmp/fulcio.b64"
	curl -sk "$(SAST_REKOR_URL)/api/v1/log/publicKey" > "$$tmp/rekor.pem"
	openssl pkey -pubin -in "$$tmp/rekor.pem" -outform DER | base64 -w0 > "$$tmp/rekor.b64"
	kubectl --kubeconfig "$(K8S_KUBECONFIG)" get secret "$(SAST_CTLOG_PUBLIC_KEY_SECRET)" -n "$(SAST_CTLOG_NAMESPACE)" -o jsonpath='{.data.public}' | base64 -d > "$$tmp/tlog.pem"
	openssl pkey -pubin -in "$$tmp/tlog.pem" -outform DER | base64 -w0 > "$$tmp/tlog.b64"
	python3 -c 'import sys,hashlib,base64,json,os; tmp=sys.argv[1]; fu=sys.argv[2]; re=sys.argv[3]; out=sys.argv[4]; b=lambda n: open(os.path.join(tmp,n)).read().strip(); k=lambda x: base64.b64encode(hashlib.sha256(base64.b64decode(x)).digest()).decode(); f,r,t=b("fulcio.b64"),b("rekor.b64"),b("tlog.b64"); tr={"mediaType":"application/vnd.dev.sigstore.trustedroot+json;version=0.1","tlogs":[{"baseUrl":re,"hashAlgorithm":"SHA2_256","publicKey":{"rawBytes":r,"keyDetails":"PKIX_ECDSA_P256_SHA_256","validFor":{"start":"2020-01-01T00:00:00.000Z"}},"logId":{"keyId":k(r)}}],"certificateAuthorities":[{"subject":{"organization":"Linux Foundation","commonName":"fulcio-ca"},"uri":fu,"certChain":{"certificates":[{"rawBytes":f}]},"validFor":{"start":"2020-01-01T00:00:00.000Z"}}],"ctlogs":[{"baseUrl":fu,"hashAlgorithm":"SHA2_256","publicKey":{"rawBytes":t,"keyDetails":"PKIX_ECDSA_P256_SHA_256","validFor":{"start":"2020-01-01T00:00:00.000Z"}},"logId":{"keyId":k(t)}}]}; open(out,"w").write(json.dumps(tr,indent=2)); print("wrote "+out)' "$$tmp" "$(SAST_FULCIO_URL)" "$(SAST_REKOR_URL)" "$(SSCS_COSIGN_TRUSTED_ROOT)"
.PHONY: sscs-cosign-trusted-root

# Usage: make sscs-cosign-signing-config
#
## Create a Sigstore signing config (cosign 3.x) pointing at the self-hosted
## Fulcio/Rekor endpoints and the cluster's OIDC issuer. cosign 3.x sign no
## longer accepts --fulcio-url/--rekor-url; the endpoints come from this file.
sscs-cosign-signing-config:
	@mkdir -p "$(dir $(SSCS_COSIGN_SIGNING_CONFIG))"

	$(SSCS_COSIGN_ALIAS) signing-config create \
		--no-default-fulcio --no-default-rekor --no-default-oidc \
		--fulcio="url=$(SAST_FULCIO_URL),api-version=1,start-time=2020-01-01T00:00:00Z,operator=self-hosted" \
		--rekor="url=$(SAST_REKOR_URL),api-version=1,start-time=2020-01-01T00:00:00Z,operator=self-hosted" \
		--rekor-config="ANY" \
		--oidc-provider="url=$(SSCS_COSIGN_OIDC_ISSUER),api-version=1,start-time=2020-01-01T00:00:00Z,operator=kubernetes" \
		--out "/workspace/$(SSCS_COSIGN_SIGNING_CONFIG)"
.PHONY: sscs-cosign-signing-config

# Usage: make sscs-cosign-sign <image_name>
#
## Sign an image against the self-hosted Fulcio/Rekor endpoints using the
## Kubernetes ServiceAccount identity. Mints a fresh SA token (audience
## `sigstore`) automatically; or pass COSIGN_TOKEN=<token> to reuse one.
##
## cosign 3.x notes:
##   --signing-config  endpoints (Fulcio/Rekor/OIDC) come from the signing config,
##                     not from --fulcio-url/--rekor-url (removed in 3.x)
##   --trusted-root    verifies the signature against the self-hosted root after
##                     signing (SCT + Rekor inclusion), instead of the public root
##   --yes             auto-accept the Rekor immutable-record consent prompt
sscs-cosign-sign: sscs-cosign-trust-bundle sscs-cosign-signing-config sscs-cosign-trusted-root
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sscs-cosign-sign <image_name>"; \
		exit 1; \
	fi
	@if [ -z "$${COSIGN_TOKEN:-}" ]; then \
		COSIGN_TOKEN=$$(kubectl --kubeconfig "$(K8S_KUBECONFIG)" create token "$(SSCS_COSIGN_SA)" -n "$(SSCS_COSIGN_SA_NAMESPACE)" --audience="$(SSCS_COSIGN_AUDIENCE)"); \
	fi

	$(SSCS_COSIGN_ALIAS) sign \
		--yes \
		--signing-config "/workspace/$(SSCS_COSIGN_SIGNING_CONFIG)" \
		--trusted-root "/workspace/$(SSCS_COSIGN_TRUSTED_ROOT)" \
		--identity-token "$$COSIGN_TOKEN" \
		"$(filter-out $@,$(MAKECMDGOALS))"
.PHONY: sscs-cosign-sign

# Usage: make sscs-cosign-verify-image <image_name>
#
## Verify an image signature against the self-hosted Rekor transparency log,
## trusting the self-hosted Sigstore root (Fulcio CA + Rekor + CT-log keys) and
## asserting the signing ServiceAccount identity.
sscs-cosign-verify-image: sscs-cosign-trust-bundle sscs-cosign-trusted-root
	@if [ -z "$(filter-out $@,$(MAKECMDGOALS))" ]; then \
		echo "usage: make sscs-cosign-verify-image <image_name>"; \
		exit 1; \
	fi

	@mkdir -p logs/sast

	$(SSCS_COSIGN_ALIAS) verify \
		--trusted-root "/workspace/$(SSCS_COSIGN_TRUSTED_ROOT)" \
		--certificate-identity "$(SSCS_COSIGN_IDENTITY)" \
		--certificate-oidc-issuer "$(SSCS_COSIGN_OIDC_ISSUER)" \
		"$(filter-out $@,$(MAKECMDGOALS))" 2> logs/sast/cosign-verify-image.log
.PHONY: sscs-cosign-verify-image

# ─── Container Manager ───────────────────────────────────────────────────────────────────────────

CONTAINER_IMAGE ?= $(notdir $(shell git rev-parse --show-toplevel 2>/dev/null))
CONTAINER_TAG ?= $(or $(shell git tag --sort=-creatordate | head -n 1),latest)
CONTAINER_CONTEXT ?= .
CONTAINER_FILE ?= container/k8s/Dockerfile

# Usage: make container-docker-build [CONTAINER_IMAGE=<name>] [CONTAINER_TAG=<tag>] [CONTAINER_FILE=<file>] [CONTAINER_CONTEXT=<context>]
#
## Build the Docker container image with the specified name, tag, and context
container-docker-build:
	docker build -f "$(CONTAINER_FILE)" -t "$(CONTAINER_IMAGE):$(CONTAINER_TAG)" "$(CONTAINER_CONTEXT)"
.PHONY: container-docker-build

# Usage: make container-docker-run [CONTAINER_IMAGE=<name>] [CONTAINER_TAG=<tag>]
#
## Run the Docker container image with the specified name and tag
container-docker-run:
	docker run --rm "$(CONTAINER_IMAGE):$(CONTAINER_TAG)"
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
CERT_DIR ?= $(K8S_CLUSTER_PATH)/secrets
CERT_DAYS ?= 365

# Usage: make cert-certificate-generate CERT_HOSTNAME=<hostname-or-url> [CERT_DIR=<directory>] [CERT_DAYS=<days>]
#
## Generate a self-signed TLS certificate for a local hostname or URL
cert-certificate-generate:
	@raw_hostname="$(strip $(CERT_HOSTNAME))"
	if [[ -z "$$raw_hostname" ]]; then
		echo "usage: make cert-certificate-generate CERT_HOSTNAME=<hostname-or-url> [CERT_DIR=<directory>] [CERT_DAYS=<days>]" >&2
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
.PHONY: cert-certificate-generate
