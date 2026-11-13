#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify repository-owned images in kubectl's JSON output before applying manifests.

Third-party workload images require separate vendor trust policies. This gate
covers the image produced by this repository, including nested Pod templates.
"""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def images_in(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "image" and isinstance(child, str):
                yield child
            yield from images_in(child)
    elif isinstance(value, list):
        for child in value:
            yield from images_in(child)


def owned_images(text, repository):
    decoder = json.JSONDecoder()
    images = set()
    while text.strip():
        document, end = decoder.raw_decode(text.lstrip())
        for image in images_in(document):
            # Include tag-only and unqualified references so the verifier rejects them.
            if image == repository or image.startswith((repository + ":", repository + "@")):
                images.add(image)
        text = text.lstrip()[end:]
    return sorted(images)


def main():
    policy_path = ROOT / ".github/sigstore/policy.json"
    policy = json.loads(policy_path.read_text())
    images = owned_images(Path(sys.argv[1]).read_text(), policy["image_repository"])
    for image in images:
        subprocess.run([sys.executable, str(ROOT / ".github/actions/sigstore/sigstore.py"),
                        "--policy", str(policy_path), "--operation", "verify", "--kind", "image",
                        "--identity", policy["identities"]["image"][0], "--image", image], check=True)
    print(f"Verified {len(images)} repository-owned image references; vendor images use separate policies.")


if __name__ == "__main__":
    main()
