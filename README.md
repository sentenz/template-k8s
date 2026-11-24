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

    - [Project Layout](docs/project-layout.md)
      > Overview of the project's directory structure and organization.

2. Usage and Instructions

    - CI/CD

      ```yaml
      uses: sentenz/actions/kind@latest
      ```

    - Tasks

      ```bash
      # Local Kubernetes Cluster using KinD
      make k8s-bootstrap
      make k8s-deploy
      make k8s-destroy
      make k8s-teardown
      ```

## 2. Contribution

[CONTRIBUTING.md](CONTRIBUTING.md) provides guidance and instructions for contributing to the project.

## 3. Troubleshoot

- [Dependency Track](apps/dependency-track/README.md#troubleshooting)
  > Troubleshooting for Dependency Track integration.

## 4. References

- Sentenz [Kubernetes](TODO) article.
- Sentenz [Template DX](https://github.com/sentenz/template-dx) repository.
- Sentenz [Actions](https://github.com/sentenz/actions) repository.
- Sentenz [Manager Tools](https://sentenz.github.io/convention/articles/manager-tools/) article.

### Private signing on the development cluster

The development deployment includes [self-hosted Sigstore](infrastructure/services/sigstore/README.md) for keyless signing, private transparency logs, and signature verification in a dedicated test namespace.
