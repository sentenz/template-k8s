# Kubernetes Toolchain Container

`ghcr.io/sentenz/k8s` is a multi-architecture Kubernetes client image containing verified, pinned releases of:

- `kubectl` v1.36.1
- Kustomize v5.8.1
- kind v0.32.0
- Helm v4.2.0

The image is a client-side tool environment. It does not replace `kindest/node`, which remains the Kubernetes node image used by clusters created with kind.

## Build

```bash
docker build \
  --tag ghcr.io/sentenz/k8s:dev \
  --file container/k8s/Dockerfile \
  .
```

The multi-stage build invokes `scripts/install-tools.sh`, verifies each upstream release artifact with SHA-256, and copies only the installed binaries into the runtime stage. The Alpine base is pinned by digest.

Tool versions can be overridden explicitly:

```bash
docker build \
  --build-arg KUBECTL_VERSION=v1.36.1 \
  --build-arg KUSTOMIZE_VERSION=v5.8.1 \
  --build-arg KIND_VERSION=v0.32.0 \
  --build-arg HELM_VERSION=v4.2.0 \
  --tag ghcr.io/sentenz/k8s:dev \
  --file container/k8s/Dockerfile \
  .
```

## Run

```bash
docker run --rm ghcr.io/sentenz/k8s:dev kubectl version --client
docker run --rm ghcr.io/sentenz/k8s:dev kustomize version
docker run --rm ghcr.io/sentenz/k8s:dev kind version
docker run --rm ghcr.io/sentenz/k8s:dev helm version --short
```

With no arguments, the container opens Bash. For compatibility with the former kind-only image, bare kind subcommands such as `create cluster`, `delete cluster`, and `version` are routed to `kind`.

Create the repository development cluster with the host Docker daemon:

```bash
docker run --rm \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  ghcr.io/sentenz/k8s:dev \
  kind create cluster \
  --name template-k8s \
  --config config/kind-cluster.yaml
```

## Security model

All downloaded tool artifacts are checksum-verified before installation. Downloads require HTTPS, TLS 1.2 or newer, fail-closed HTTP behavior, and bounded retries. Versions are pinned and validated; no upstream installation script is piped into a shell.

Mounting `/var/run/docker.sock` grants effectively privileged control over the host Docker daemon. It is not a sandbox or least-privilege boundary. Do not expose the socket to untrusted pull-request code or untrusted images. Prefer isolated or ephemeral runners for containerized kind execution. The runtime image retains root as the default because socket group ownership is host-specific; use `--user` only where the mounted socket and workspace permissions are explicitly configured.

## Publication

`.github/workflows/k8s-container.yml` validates image changes on pull requests and pushes to `main`. A semantic Git tag such as `v1.2.3` publishes the immutable `ghcr.io/sentenz/k8s:v1.2.3` manifest after both architecture candidates pass smoke tests and critical-vulnerability scans. Stable tags also promote `latest`; prerelease tags do not.

Publication is serialized per image version and refuses to overwrite an existing immutable tag. Published images include OCI metadata, BuildKit provenance, and an SBOM.
