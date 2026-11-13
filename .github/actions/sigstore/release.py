#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Create or check a release inventory. Verify its signature before calling verify."""
import hashlib
import json
from pathlib import Path
import re
import sys

ARTIFACTS = ("source.tar.gz", "source.zip", "sbom.cdx.json", "sbom.spdx.json")


def digest(path):
    if path.is_symlink() or not path.is_file() or not path.stat().st_size:
        raise ValueError(f"Missing, empty, or symlinked artifact: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create(version, commit):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit")
    manifest = {"version": version, "source_commit": commit,
                "sha256": {name: digest(Path(name)) for name in ARTIFACTS}}
    Path("release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def verify(version, directory):
    directory = Path(directory)
    manifest = json.loads((directory / "release-manifest.json").read_text())
    if manifest["version"] != version or set(manifest["sha256"]) != set(ARTIFACTS):
        raise ValueError("Release inventory or version mismatch")
    for name in ARTIFACTS:
        if digest(directory / name) != manifest["sha256"][name]:
            raise ValueError(f"Release digest mismatch: {name}")
    signed = {*ARTIFACTS, "release-manifest.json"}
    expected = signed | {name + ".sigstore.json" for name in signed}
    expected |= {"image-reference.txt", "image.sigstore.json"}
    if {path.name for path in directory.iterdir()} != expected:
        raise ValueError("Missing or unexpected release assets")
    for name in expected:
        digest(directory / name)
    image = (directory / "image-reference.txt").read_text()
    if not re.fullmatch(r"[^@\s]+@sha256:[0-9a-f]{64}\n?", image):
        raise ValueError("Invalid release image reference")


if __name__ == "__main__":
    try:
        operation, version, argument = sys.argv[1:]
        if not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
            raise ValueError("Invalid release version")
        if operation == "create":
            create(version, argument)
        elif operation == "verify":
            verify(version, argument)
        else:
            raise ValueError("Expected create or verify")
    except (ValueError, KeyError, OSError) as error:
        sys.exit(str(error))
