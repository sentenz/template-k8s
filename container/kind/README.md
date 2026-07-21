# kind CLI Container

The `ghcr.io/sentenz/kind` image provides a small, versioned execution environment for the [`kind`](https://kind.sigs.k8s.io/) CLI.

This image is a client-side tool container. It does not replace `kindest/node`, which remains the Kubernetes node image used by clusters created with kind.

## Build

Build the image for the host architecture:

```bash
docker build \
  --build-arg KIND_VERSION=v0.32.0 \
  --tag ghcr.io/sentenz/kind:v0.32.0 \
  --file container/kind/Dockerfile \
  .
```

The Dockerfile downloads the selected kind release binary and verifies it using the checksum published with that release. The default Alpine base image is pinned by digest.

Build both supported platforms with Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg KIND_VERSION=v0.32.0 \
  --tag ghcr.io/sentenz/kind:v0.32.0 \
  --file container/kind/Dockerfile \
  .
```

## Run

Display the embedded kind version:

```bash
docker run --rm ghcr.io/sentenz/kind:v0.32.0 version
```

Create the repository development cluster with the host Docker daemon:

```bash
docker run --rm \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  ghcr.io/sentenz/kind:v0.32.0 \
  create cluster \
  --name template-k8s \
  --config config/kind-cluster.yaml
```

The repository mount exposes the Kind configuration to the CLI container. The Docker socket allows kind to create and manage node containers on the host daemon. Host networking keeps the CLI container in the same loopback namespace as the Docker host so it can reach the Kubernetes API endpoint created by kind. On Docker Desktop, host networking must be supported and enabled; otherwise use a runtime-specific API address that is reachable from the CLI container.

Delete the cluster with the same execution model:

```bash
docker run --rm \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/sentenz/kind:v0.32.0 \
  delete cluster \
  --name template-k8s
```

## Security model

Mounting `/var/run/docker.sock` grants the container effectively privileged control over the host Docker daemon. A process with access to that socket can create privileged containers, mount host paths, and modify or remove host containers and images. This execution model is not a sandbox or a least-privilege boundary.

Accordingly:

- do not expose the Docker socket to untrusted pull-request code or untrusted image contents;
- use an isolated or ephemeral runner when containerized kind execution is required in automation;
- prefer installing the kind release binary directly, or retain the repository's `helm/kind-action` integration, when a containerized toolchain is not required;
- use a rootless Docker or Podman socket only where the selected runtime and kind configuration are explicitly supported, and mount the runtime-specific socket rather than assuming `/var/run/docker.sock`;
- treat membership in the host runtime socket group as privileged access.

The repository's existing `helm/kind-action` integration remains the default GitHub Actions path. The custom image is built, scanned, and smoke-tested independently.

## Publication

The `.github/workflows/kind-container.yml` workflow validates image changes on pull requests and runs on pushes to `main` so tag-triggered publication remains reliable.

Immutable version publication uses either:

- a trusted tag named `kind-v<version>`, for example `kind-v0.32.0`; or
- a manually dispatched workflow with `publish` enabled and an explicit `kind-version` value.

Publication jobs are serialized by the resolved kind version, and the workflow refuses to overwrite an existing version tag in `ghcr.io/sentenz/kind`. The optional `latest` tag is updated only when `update-latest` is explicitly enabled during a manual publication.

Published images target `linux/amd64` and `linux/arm64`, include OCI metadata, BuildKit provenance, and an SBOM, and are scanned for critical vulnerabilities.

A full cluster-creation test is available only through explicit manual dispatch. It mounts the Docker socket on a trusted ephemeral GitHub-hosted runner and is intentionally excluded from pull-request execution.
