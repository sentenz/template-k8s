#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Policy enforcement shared by CI and artifact consumers. Requires Cosign 3.1.4."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

VERSION = "v3.1.4"
PUBLIC_TUF = "https://tuf-repo-cdn.sigstore.dev"
GITHUB_ISSUER = "https://token.actions.githubusercontent.com"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular_file(name):
    path = Path(name)
    require(path.is_file() and not path.is_symlink(), f"Missing or symlinked file: {name}")
    require(path.stat().st_size > 0, f"Empty file: {name}")
    return path.resolve()


def pinned_file(policy_path, spec):
    path = regular_file(policy_path.parent / spec["path"])
    require(hashlib.sha256(path.read_bytes()).hexdigest() == spec["sha256"],
            f"Unapproved trust configuration: {path}")
    return path


def validate(args):
    policy_path = regular_file(args.policy)
    policy = json.loads(policy_path.read_text())
    require(not args.release_version or re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.release_version),
            "Invalid release version")
    require(args.identity in policy["identities"][args.kind], "Unauthorized workload identity")
    require(policy["issuer"].startswith("https://"), "An explicit HTTPS OIDC issuer is required")
    require(policy["deployment"] in ("public", "private"), "Select public or private Sigstore")
    if policy["deployment"] == "public":
        require(policy.get("public_metadata_permitted") is True,
                "Public signing metadata disclosure is not approved")
        require(not policy.get("trusted_root") and not policy.get("signing_config"),
                "Public mode uses only the embedded Sigstore TUF trust anchor")
    else:
        root = pinned_file(policy_path, policy["trusted_root"])
        trust = json.loads(root.read_text())
        require(all(trust.get(key) for key in ("certificateAuthorities", "tlogs", "ctlogs")),
                "Private trust must include Fulcio, Rekor, and CT trust material")
        if args.operation == "sign":
            config = pinned_file(policy_path, policy["signing_config"])
            data = json.loads(config.read_text())
            require(data.get("caUrls") and data.get("rekorTlogUrls"),
                    "Private signing requires explicit Fulcio and Rekor endpoints")
            # No fallback to public services, including public timestamp services.
            def check_urls(value):
                if isinstance(value, dict):
                    for key, child in value.items():
                        if key == "url":
                            parsed = urlparse(child)
                            require(parsed.scheme == "https" and parsed.hostname,
                                    "Private signing endpoints must use HTTPS")
                            require(not parsed.hostname.endswith("sigstore.dev"),
                                    "Public Sigstore endpoint in private signing configuration")
                        check_urls(child)
                elif isinstance(value, list):
                    for child in value:
                        check_urls(child)
            check_urls(data)
    if args.operation == "sign":
        require(os.environ.get("GITHUB_ACTIONS") == "true", "Signing requires GitHub Actions OIDC")
        require(os.environ.get("GITHUB_REPOSITORY") == policy["repository"], "Unapproved repository")
        require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Signing is restricted to main")
        require(os.environ.get("GITHUB_EVENT_NAME") in ("push", "workflow_dispatch"),
                "Signing is forbidden for pull requests and other untrusted events")
        require(policy["issuer"] == GITHUB_ISSUER,
                "Private Fulcio must trust GitHub Actions with audience sigstore")
        require(all(os.environ.get(key) for key in
                    ("ACTIONS_ID_TOKEN_REQUEST_URL", "ACTIONS_ID_TOKEN_REQUEST_TOKEN")),
                "Signing job requires id-token: write")
    files = [regular_file(name) for name in args.files.splitlines() if name.strip()]
    if args.kind == "image":
        # Accept an optional human-readable tag, but always operate on the digest.
        match = re.fullmatch(r"([^@]+)@sha256:([0-9a-f]{64})", args.image)
        require(match is not None, "An immutable sha256 image reference is required")
        reference = match[1]
        tag_separator = reference.rfind(":")
        repository = reference[:tag_separator] if tag_separator > reference.rfind("/") else reference
        require(repository == policy["image_repository"], "Unapproved image repository")
        args.image = f"{repository}@sha256:{match[2]}"
        require(not files, "Image operations cannot include blobs")
        require(args.bundle and not Path(args.bundle).is_symlink(), "Invalid image bundle path")
    else:
        require(files and len(set(files)) == len(files), "An explicit nonempty, unique file list is required")
        require(not args.image, "Blob operations cannot include an image")
        for path in files:
            require(not str(path).endswith(".sigstore.json"), "A bundle is not a signable artifact")
            bundle = Path(str(path) + ".sigstore.json")
            require(not bundle.is_symlink(), "Symlinked bundle is forbidden")
            if args.operation == "verify":
                regular_file(bundle)
    return policy_path, policy, files


def execute(args):
    policy_path, policy, files = validate(args)
    # Trust and identity cannot be overridden through ambient Cosign configuration.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("SIGSTORE_", "COSIGN_", "TUF_"))}

    def run(*command, capture=False):
        return subprocess.run(["cosign", *map(str, command)], check=True, env=env,
                              text=True, stdout=subprocess.PIPE if capture else None)

    require(json.loads(run("version", "--json", capture=True).stdout)["gitVersion"] == VERSION,
            f"Cosign {VERSION} is required")
    with tempfile.TemporaryDirectory(prefix="sigstore-trust-") as cache:
        env["TUF_ROOT"] = cache
        signing_config = []
        if policy["deployment"] == "public":
            run("initialize", "--mirror", PUBLIC_TUF)
            roots = list(Path(cache).rglob("trusted_root.json"))
            require(len(roots) == 1, "TUF did not provide a unique trusted root")
            root = roots[0]
        else:
            root = pinned_file(policy_path, policy["trusted_root"])
            if args.operation == "sign":
                signing_config = ["--signing-config", pinned_file(policy_path, policy["signing_config"])]
        trust = ["--trusted-root", root]
        identity = ["--certificate-identity", args.identity,
                    "--certificate-oidc-issuer", policy["issuer"]]
        signing = ["--yes", "--oidc-provider", "github-actions", "--oidc-client-id", "sigstore",
                   *signing_config, *trust]
        if args.kind == "image":
            annotations = ["-a", f"release-version={args.release_version}"] if args.release_version else []
            if args.operation == "sign":
                require(args.release_version, "Image signing requires a release version")
                run("sign", *signing, *annotations, "--bundle", args.bundle, args.image)
                regular_file(args.bundle)
            # Registry verification also checks the signed digest claims, SCT and Rekor evidence.
            run("verify", *trust, *identity, *annotations, args.image)
        else:
            for path in files:
                bundle = str(path) + ".sigstore.json"
                before = hashlib.sha256(path.read_bytes()).digest()
                if args.operation == "sign":
                    run("sign-blob", *signing, "--bundle", bundle, path)
                run("verify-blob", *trust, *identity, "--bundle", bundle, path)
                require(hashlib.sha256(path.read_bytes()).digest() == before,
                        f"Artifact changed during verification: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name, default in (("operation", "verify"), ("kind", "release"), ("identity", ""),
                          ("policy", ".github/sigstore/policy.json"), ("image", ""),
                          ("files", ""), ("bundle", "image.sigstore.json"), ("release_version", "")):
        options = {"default": os.environ.get("SIGSTORE_" + name.upper(), default)}
        if name == "operation":
            options["choices"] = ("sign", "verify")
        if name == "kind":
            options["choices"] = ("image", "release", "firmware")
        parser.add_argument("--" + name.replace("_", "-"), **options)
    args = parser.parse_args()
    # argparse does not validate defaults obtained from the environment.
    require(args.operation in ("sign", "verify"), "Invalid operation")
    require(args.kind in ("image", "release", "firmware"), "Invalid artifact kind")
    execute(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Sigstore policy rejected operation: {error}", file=sys.stderr)
        sys.exit(1)
