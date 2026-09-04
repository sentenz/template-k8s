# Kubernetes Toolchain Container

- [1. Build](#1-build)
- [2. Run](#2-run)
- [3. Security model](#3-security-model)
- [4. Publication](#4-publication)

`ghcr.io/sentenz/k8s` is a multi-architecture Kubernetes client image
containing verified, pinned releases of:

- `kubectl` v1.36.2
- Kustomize v5.8.1
- kind v0.32.0
- Helm v4.2.4

The image is a client-side tool environment. It does not replace
`kindest/node`, which remains the Kubernetes node image used by clusters
created with kind.

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

The multi-stage build copies `kubectl` and Kustomize from the digest-pinned
`alpine/k8s` image and Helm from the digest-pinned `alpine/helm` image.
Because no dedicated kind image is available, `scripts/bootstrap.sh` downloads
and SHA-256 verifies only the kind binary in an isolated tool stage. The
runtime stage receives only the four required binaries. No compilation occurs
during the build. The Alpine base is pinned by digest and receives current
security upgrades during the build.

The kind version can be overridden explicitly:

```bash
docker build \
  --build-arg KIND_VERSION=v0.32.0 \
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
  --user root \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  ghcr.io/sentenz/k8s:latest \
  kind create cluster \
  --name template-k8s \
  --config clusters/dev/kind-cluster.yaml
```

## 3. Security model

The kind download requires HTTPS, HTTPS-only redirects, TLS 1.2 or newer,
fail-closed HTTP behavior, bounded retries, and an explicit connection
timeout. Its version and checksum format are validated, and the checksum
manifest must contain an exact asset match. The remaining tools come from
digest-pinned source images. No upstream installation script is piped into a
shell.

> [!NOTE]
> The runtime image uses the unprivileged `k8s` user and group (UID/GID
> `10001`) by default. Mounting `/var/run/docker.sock` grants effectively
> privileged control over the host Docker daemon and requires an explicit user
> override when the socket is owned by root. It is not a sandbox or
> least-privilege boundary. Do not expose the socket to untrusted pull-request
> code or untrusted images. Prefer isolated or ephemeral runners for
> containerized kind execution.

## 4. Publication

`.github/workflows/docker.yml` validates image changes on pull requests and is
called by the release workflow to publish images. A semantic Git tag such as
`v1.2.3` publishes the immutable `ghcr.io/sentenz/k8s:v1.2.3` manifest after
both architecture candidates pass smoke tests and critical-vulnerability
scans. Stable tags also promote `latest`; prerelease tags do not.

Publication is serialized per image version and refuses to overwrite an
existing immutable tag. Published images include OCI metadata, BuildKit
provenance, and an SBOM.
