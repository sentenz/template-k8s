# `scripts/`

- `install-tools.sh` installs pinned Kubernetes CLI tools from upstream release assets. Every binary or archive is verified with SHA-256 before installation. The script supports `linux/amd64` and `linux/arm64`, BuildKit `TARGETOS`/`TARGETARCH`, a configurable `INSTALL_DIR`, and a comma- or space-separated `TOOLS` selection.
- `bootstrap.sh` selects a writable host installation directory and delegates all Kubernetes CLI installation to `install-tools.sh`.
- `setup.sh` configures the remaining development environment.
- `teardown.sh` removes development artifacts and reverses local setup where supported.

Default tool versions are intentionally pinned in `install-tools.sh` and mirrored as Docker build arguments. Override `KUBECTL_VERSION`, `KUSTOMIZE_VERSION`, `KIND_VERSION`, or `HELM_VERSION` only with an upstream release tag. Optional `*_SHA256` variables can supply externally pinned checksums for hermetic or controlled-network builds.

Example:

```bash
INSTALL_DIR="$HOME/.local/bin" \
TOOLS="kubectl,kustomize,kind,helm" \
./scripts/install-tools.sh
```
