# `scripts/`

- `install-tools.sh` installs pinned Kubernetes CLI tools for `linux/amd64` and `linux/arm64`. Upstream binaries and archives are verified with SHA-256 before installation. Kustomize is compiled from its pinned Go module using a checksum-pinned Go toolchain and the public Go checksum database because the current upstream Kustomize release binary embeds a vulnerable Go standard library.
- `bootstrap.sh` selects a writable host installation directory and delegates all Kubernetes CLI installation to `install-tools.sh`.
- `setup.sh` configures the remaining development environment.
- `teardown.sh` removes development artifacts and reverses local setup where supported.

The installer supports BuildKit `TARGETOS`/`TARGETARCH`, a configurable absolute `INSTALL_DIR`, and a comma- or space-separated `TOOLS` selection. Default tool versions are intentionally pinned in `install-tools.sh` and mirrored as Docker build arguments.

Override `KUBECTL_VERSION`, `KUSTOMIZE_VERSION`, `KIND_VERSION`, or `HELM_VERSION` only with an upstream release tag. `KUBECTL_SHA256`, `KIND_SHA256`, and `HELM_SHA256` can provide externally pinned checksums for controlled-network builds. Overriding `GO_VERSION` requires the matching official `GO_SHA256`; the default Go checksums for both supported architectures are embedded in the installer.

Example:

```bash
INSTALL_DIR="$HOME/.local/bin" \
TOOLS="kubectl,kustomize,kind,helm" \
bash ./scripts/install-tools.sh
```
