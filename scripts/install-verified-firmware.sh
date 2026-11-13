#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Verify and stage firmware bytes for a device-specific updater. Does not flash hardware.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 FIRMWARE DESTINATION" >&2; exit 2; }
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
staging_dir="$(mktemp -d)"
trap 'rm -rf -- "$staging_dir"' EXIT
cp -- "$1" "$staging_dir/firmware.bin"
cp -- "$1.sigstore.json" "$staging_dir/firmware.bin.sigstore.json"
python3 "$repository_root/.github/actions/sigstore/sigstore.py" \
  --policy "$repository_root/.github/sigstore/policy.json" \
  --operation verify --kind firmware --files "$staging_dir/firmware.bin" \
  --identity https://github.com/sentenz/template-k8s/.github/workflows/firmware.yml@refs/heads/main
install -m 0644 -- "$staging_dir/firmware.bin" "$2"
