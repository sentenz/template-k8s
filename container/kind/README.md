# Kubernetes CLI Toolchain Container

The `ghcr.io/sentenz/k8s` image provides a versioned client environment containing:

- [`kubectl`](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/)
- [`kind`](https://kind.sigs.k8s.io/)
- [Helm](https://helm.sh/)

The image is a client-side toolchain. It does not replace `kindest/node`, which remains the Kubernetes node image used by clusters created with kind.

## Build

Build the image for the host architecture:

```bash
docker build \
  --tag ghcr.io/sentenz/k8s:v0.32.0 \
  --file container/kind/Dockerfile \
  .
```

Override individual tool versions with build arguments:

```bash
docker build \
  --build-arg KUBECTL_VERSION=v1.36.1 \
  --build-arg KUSTOMIZE_VERSION=v5.8.1 \
  --build-arg KIND_VERSION=v0.32.0 \
  --build-arg HELM_VERSION=v4.1.4 \
  --tag ghcr.io/sentenz/k8s:v0.32.0 \
  --file container/kind/Dockerfile \
  .
```

Build and publish both supported platforms with Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/sentenz/k8s:v0.32.0 \
  --file container/kind/Dockerfile \
  --push \
  .
```

The Dockerfile uses `scripts/install-k8s-tools.sh` for every tool. Kubectl, kind, and Helm release artifacts are downloaded over HTTPS and verified against either publisher-hosted checksum sidecars or explicitly supplied SHA-256 pins.

Kustomize uses the installer's source-build mode. Its exact Go module tag is compiled with a digest-pinned Go `1.24.13` builder, Go module checksum verification remains enabled, and the resulting binary metadata is checked against the requested Kustomize module, version, and toolchain before it enters the runtime image. This avoids inheriting vulnerabilities from an upstream release binary built with an obsolete Go toolchain.

For a fail-closed build of the downloaded tools, set `CHECKSUM_POLICY=pinned` and provide architecture-specific digest arguments:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg CHECKSUM_POLICY=pinned \
  --build-arg KUBECTL_SHA256_AMD64='<sha256>' \
  --build-arg KUBECTL_SHA256_ARM64='<sha256>' \
  --build-arg KIND_SHA256_AMD64='<sha256>' \
  --build-arg KIND_SHA256_ARM64='<sha256>' \
  --build-arg HELM_SHA256_AMD64='<sha256>' \
  --build-arg HELM_SHA256_ARM64='<sha256>' \
  --tag ghcr.io/sentenz/k8s:v0.32.0 \
  --file container/kind/Dockerfile \
  --push \
  .
```

## Run tools

Explicit tool names are dispatched directly:

```bash
docker run --rm ghcr.io/sentenz/k8s:v0.32.0 kubectl version --client=true
docker run --rm ghcr.io/sentenz/k8s:v0.32.0 kustomize version
docker run --rm ghcr.io/sentenz/k8s:v0.32.0 kind version
docker run --rm ghcr.io/sentenz/k8s:v0.32.0 helm version --short
```

For compatibility with the former kind-only image, arguments that do not begin with a supported tool name are treated as kind subcommands. Running the image without arguments displays the embedded kind version.

Create the repository development cluster with the host Docker daemon:

```bash
docker run --rm \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  ghcr.io/sentenz/k8s:v0.32.0 \
  create cluster \
  --name template-k8s \
  --config config/kind-cluster.yaml
```

Delete the cluster with the same execution model:

```bash
docker run --rm \
  --network host \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/sentenz/k8s:v0.32.0 \
  delete cluster \
  --name template-k8s
```

## Security model

Mounting `/var/run/docker.sock` grants the container effectively privileged control over the host Docker daemon. A process with access to that socket can create privileged containers, mount host paths, and modify or remove host containers and images. This execution model is not a sandbox or a least-privilege boundary.

Accordingly:

- do not expose the Docker socket to untrusted pull-request code or untrusted image contents;
- use an isolated or ephemeral runner when containerized kind execution is required in automation;
- prefer direct tool installation when a containerized toolchain is not required;
- use a rootless Docker or Podman socket only where the selected runtime and kind configuration are explicitly supported;
- treat membership in the host runtime socket group as privileged access;
- pin published image references by digest in production automation.

The installer additionally rejects unsafe archive members, symlinked installation targets, insecure installation directories, malformed versions, unsupported platforms, and checksum mismatches.

## Publication

The `.github/workflows/kind-container.yml` workflow validates image changes on pull requests and relevant pushes to `main`. Trusted semantic-version tag pushes and explicit workflow dispatches can publish immutable tags to `ghcr.io/sentenz/k8s`.

Release candidates are built separately for `linux/amd64` and `linux/arm64`, scanned for critical operating-system and library vulnerabilities, and published by digest. The multi-platform version manifest is created only after both scans pass. Published images include OCI metadata, BuildKit provenance, and an SBOM.

The workflow refuses to overwrite an existing immutable version tag. The moving `latest` tag is managed as an explicit promotion operation. A full cluster-creation test is available only through manual dispatch because it requires mounting the Docker socket on a trusted runner.
