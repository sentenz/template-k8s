# Kubernetes Toolchain Container

- [1. Build](#1-build)
- [2. Run](#2-run)
- [3. Security model](#3-security-model)
- [4. Publication](#4-publication)

`ghcr.io/sentenz/k8s` is a multi-architecture Kubernetes client image containing verified, pinned releases of:

- `kubectl` v1.36.1
- Kustomize v5.8.1
- kind v0.32.0
- Helm v4.2.0

The image is a client-side tool environment. It does not replace `kindest/node`, which remains the Kubernetes node image used by clusters created with kind.

## 1. Build

```bash
docker build \
  --tag ghcr.io/sentenz/k8s:latest \
  --file container/k8s/Dockerfile \
  .
```

Alternatively, use the Make target:

```bash
make container-docker-build
```

The multi-stage build invokes `scripts/bootstrap.sh` and downloads precompiled, SHA-256 verified binaries for all tools into the build stage, then copies only the resulting binaries into the runtime stage. No compilation occurs during the build. The Alpine base is pinned by digest and receives current security upgrades during the build.

Tool versions can be overridden explicitly:

```bash
docker build \
  --build-arg KUBECTL_VERSION=v1.36.1 \
  --build-arg KUSTOMIZE_VERSION=v5.8.1 \
  --build-arg KIND_VERSION=v0.32.0 \
  --build-arg HELM_VERSION=v4.2.0 \
  --tag ghcr.io/sentenz/k8s:latest \
  --file container/k8s/Dockerfile \
  .
```

## 2. Run

```bash
docker run --rm ghcr.io/sentenz/k8s:latest kubectl version --client
docker run --rm ghcr.io/sentenz/k8s:latest kustomize version
docker run --rm ghcr.io/sentenz/k8s:latest kind version
docker run --rm ghcr.io/sentenz/k8s:latest helm version --short
```

With no arguments, the container opens a Bash shell.

Create the repository development cluster with the host Docker daemon:

```bash
docker run --rm \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  ghcr.io/sentenz/k8s:latest \
  kind create cluster \
  --name template-k8s \
  --config config/kind-cluster.yaml
```

## 3. Security model

Downloads require HTTPS, HTTPS-only redirects, TLS 1.2 or newer, fail-closed HTTP behavior, bounded retries, and an explicit connection timeout. Versions and checksum formats are validated; named checksum manifests must contain an exact asset match. All tools are installed from precompiled release binaries with SHA-256 verification. No upstream installation script is piped into a shell.

Mounting `/var/run/docker.sock` grants effectively privileged control over the host Docker daemon. It is not a sandbox or least-privilege boundary. Do not expose the socket to untrusted pull-request code or untrusted images. Prefer isolated or ephemeral runners for containerized kind execution. The runtime image retains root as the default because socket group ownership is host-specific; use `--user` only where the mounted socket and workspace permissions are explicitly configured.

## 4. Publication

`.github/workflows/k8s-container.yml` validates image changes on pull requests and pushes to `main`. A semantic Git tag such as `v1.2.3` publishes the immutable `ghcr.io/sentenz/k8s:v1.2.3` manifest after both architecture candidates pass smoke tests and critical-vulnerability scans. Stable tags also promote `latest`; prerelease tags do not.

Publication is serialized per image version and refuses to overwrite an existing immutable tag. Published images include OCI metadata, BuildKit provenance, and an SBOM.
