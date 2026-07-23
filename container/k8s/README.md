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

The multi-stage build invokes `scripts/install-tools.sh` and copies only the resulting binaries into the runtime stage. Upstream binaries and archives are SHA-256 verified. Kustomize is compiled from its pinned module using checksum-pinned Go 1.25.11 and the public Go checksum database; this avoids the Critical Go standard-library vulnerability embedded in the current upstream Kustomize release binary. The Alpine base is pinned by digest and receives current security upgrades during the build.

Tool versions can be overridden explicitly:

```bash
docker build \
  --build-arg KUBECTL_VERSION=v1.36.1 \
  --build-arg KUSTOMIZE_VERSION=v5.8.1 \
  --build-arg KIND_VERSION=v0.32.0 \
  --build-arg HELM_VERSION=v4.2.0 \
  --build-arg GO_VERSION=1.25.11 \
  --tag ghcr.io/sentenz/k8s:dev \
  --file container/k8s/Dockerfile \
  .
```

A non-default Go version requires the matching official `GO_SHA256` when invoking the installer directly. Docker release builds intentionally use the pinned default builder toolchain.

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

Downloads require HTTPS, HTTPS-only redirects, TLS 1.2 or newer, fail-closed HTTP behavior, bounded retries, and an explicit connection timeout. Versions and checksum formats are validated; named checksum manifests must contain an exact asset match. No upstream installation script is piped into a shell.

Kustomize module source and transitive dependencies are resolved through `proxy.golang.org` and authenticated by `sum.golang.org`. Go environment files, private-module patterns, workspace mode, VCS metadata, and CGO are disabled for the build. The temporary Go toolchain and module caches do not enter the runtime image.

Mounting `/var/run/docker.sock` grants effectively privileged control over the host Docker daemon. It is not a sandbox or least-privilege boundary. Do not expose the socket to untrusted pull-request code or untrusted images. Prefer isolated or ephemeral runners for containerized kind execution. The runtime image retains root as the default because socket group ownership is host-specific; use `--user` only where the mounted socket and workspace permissions are explicitly configured.

## Publication

`.github/workflows/k8s-container.yml` validates image changes on pull requests and pushes to `main`. A semantic Git tag such as `v1.2.3` publishes the immutable `ghcr.io/sentenz/k8s:v1.2.3` manifest after both architecture candidates pass smoke tests and critical-vulnerability scans. Stable tags also promote `latest`; prerelease tags do not.

Publication is serialized per image version and refuses to overwrite an existing immutable tag. Published images include OCI metadata, BuildKit provenance, and an SBOM.
