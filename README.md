# Kubernetes

Orchestration platform for automating deployment, scaling, and management of containerized applications.

- [1. Details](#1-details)
  - [1.1. Prerequisites](#11-prerequisites)
  - [1.2. Usage](#12-usage)
- [2. Contribution](#2-contribution)
- [3. Troubleshoot](#3-troubleshoot)
- [4. References](#4-references)

## 1. Details

### 1.1. Prerequisites

> [!TIP]
> [Alpine Linux Collection](https://hub.docker.com/u/alpine) of verified tools for local Kubernetes workflows based on a security-oriented, lightweight Linux distribution image.

- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
  > Command-line tool for interacting with Kubernetes clusters.

- [Helm](https://helm.sh/)
  > Package manager for Kubernetes for application deployment and management.

- [kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/)
  > Command-line tool for customizing Kubernetes resource configurations.

- [kind](https://kubernetes.io/docs/tasks/tools/#kind)
  > Command-line tool for running local Kubernetes clusters using Docker.

- [Docker](https://www.docker.com/)
  > Containerization platform for building, shipping, and running containerized applications.

- [Make](https://www.gnu.org/software/make/)
  > Task automation tool to manage build processes and workflows.

  ```bash
  sudo apt install make
  ```

### 1.2. Usage

1. Insights and Details

    - [Architecture](docs/architecture.md)
      > High-level overview of the system's structure, components, and interactions.

2. Usage and Instructions

    - CI/CD

      ```yaml
      uses: sentenz/actions/kind@latest
      ```

    - Tasks

      ```bash
      # Local Kubernetes Cluster using KinD
      make k8s-setup
      make k8s-deploy
      make k8s-destroy
      make k8s-teardown
      ```

## 2. Contribution

[CONTRIBUTING.md](CONTRIBUTING.md) provides guidance and instructions for contributing to the project.

- [AI Agents](CONTRIBUTING.md#1-ai-agents)
  > Automated tools that assist in various development tasks such as code generation, testing, and documentation.

- [Skills Manager](CONTRIBUTING.md#2-skills-manager)
  > CLI tool for managing AI agent skills in development projects.

- [Task Runner](CONTRIBUTING.md#3-task-runner)
  > Make automation tool that defines and manages tasks to streamline development workflows.

- [Bootstrap](CONTRIBUTING.md#4-bootstrap)
  > Scripts to bootstrap, setup, and teardown a software development workspace with requisites.

- [Secrets Manager](CONTRIBUTING.md#9-secrets-manager)
  > Manage and secure sensitive information such as API keys, passwords, and certificates.

- [Git Hooks Manager](CONTRIBUTING.md#5-git-hooks-manager)
  > Lefthook configuration for managing Git hooks to automate Git events on commit or push.

- [Dev Containers](CONTRIBUTING.md#6-dev-containers)
  > Consistent development environments using Docker containers.

- [Release Manager](CONTRIBUTING.md#7-release-manager)
  > Semantic-Release automates the release process by analyzing commit messages.

- [Update Manager](CONTRIBUTING.md#8-update-manager)
  > Renovate and Dependabot automate dependency updates by creating pull requests.

- [Policy Manager](CONTRIBUTING.md#11-policy-manager)
  > Conftest for policy-as-code enforcement.

- [SAST Manager](CONTRIBUTING.md#12-sast-manager)
  > Identifying security vulnerabilities and issues in source code, container images, and artifacts.

- [Supply Chain Manager](CONTRIBUTING.md#13-supply-chain-manager)
  > Software Supply Chain Security for identifying vulnerabilities in dependencies by scanning SBOMs, container images, filesystems, and compliance issues.

- [Documentation Generators](CONTRIBUTING.md#14-documentation-generators)
  > MkDocs for building and serving the documentation site.

## 3. Troubleshoot

1. General Diagnostics

    - Service Diagnostics
      > Run the default read-only troubleshooting workflow for cluster connectivity, workload health, namespace scanning, rollout information, logs, networking, and RBAC checks.

      ```bash
      make k8s-troubleshoot K8S_RESOURCE_NAME=<deployment>
      ```

    - Cluster and Namespace Health
      > Validate Kubernetes API and control-plane connectivity, or scan namespace resources for operational issues using containerized Popeye.

      ```bash
      make k8s-preflight
      make k8s-health-scan
      ```

2. Workload Diagnostics

    - Workload State and Logs
      > Inspect workload state, rollout information, current and previous container logs, or follow live multi-Pod logs using containerized Stern.

      ```bash
      make k8s-monitor K8S_RESOURCE_NAME=<deployment>
      make k8s-describe K8S_RESOURCE_NAME=<deployment>
      make k8s-logs K8S_RESOURCE_NAME=<deployment>
      make k8s-logs-previous K8S_RESOURCE_NAME=<deployment>
      make k8s-logs-follow K8S_RESOURCE_NAME=<deployment>
      ```

    - Pod and Node Diagnostics
      > Drill down into a selected Pod or Node after general diagnostics identify a specific failing resource.

      ```bash
      make k8s-pod-diagnose K8S_POD=<pod>
      make k8s-node-diagnose K8S_NODE=<node>
      ```

    - Interactive Console
      > Explore Kubernetes resources using containerized K9s in read-only mode by default.

      ```bash
      make k8s-console
      ```

3. Connectivity and Runtime Diagnostics

    - Network and Authorization Diagnostics
      > Inspect Services, EndpointSlices, Ingresses, NetworkPolicies, and effective Kubernetes RBAC permissions.

      ```bash
      make k8s-network-diagnose K8S_SERVICE_NAME=<service>
      make k8s-auth-diagnose
      make k8s-auth-diagnose K8S_SERVICE_ACCOUNT=<service-account>
      ```

    - Database and Storage Diagnostics
      > Validate application-to-database DNS and TCP connectivity. Development uses Kubernetes PostgreSQL, while stage and production require an AWS RDS endpoint. Kubernetes-managed PostgreSQL storage diagnostics apply to development only.

      ```bash
      make k8s-database-diagnose K8S_ENV=dev
      make k8s-database-diagnose K8S_ENV=stage K8S_DATABASE_HOST=<rds-endpoint>
      make k8s-storage-diagnose K8S_ENV=dev
      ```

    - Application and Desired State Diagnostics
      > Verify application reachability from inside the namespace or compare rendered Kustomize and Helm desired state against live Kubernetes resources.

      ```bash
      make k8s-smoke-test K8S_SMOKE_TEST_URL=<url>
      make k8s-diff K8S_ENV=<dev|stage|prod>
      ```

    - Ephemeral Debug
      > Attach a containerized Netshoot ephemeral debug container to a selected Pod for deeper network and runtime diagnostics.

      ```bash
      make k8s-debug K8S_POD=<pod>
      make k8s-debug K8S_POD=<pod> K8S_DEBUG_TARGET=<container>
      ```

4. Integration Diagnostics

    - [Dependency Track](manifests/base/dependency-track/README.md#12-troubleshoot)
      > Integration-specific troubleshooting for ingress routing, TLS, external host reachability, and local Kind host-network or DNS behavior.

## 4. References

- Sentenz [Kubernetes](TODO) article.
- Sentenz [Template DX](https://github.com/sentenz/template-dx) repository.
- Sentenz [Actions](https://github.com/sentenz/actions) repository.
- Sentenz [Manager Tools](https://sentenz.github.io/convention/articles/manager-tools/) article.
