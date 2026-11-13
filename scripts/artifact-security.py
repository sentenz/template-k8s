#!/usr/bin/env python3
"""Fail-closed Cosign v3 policy entry point; no keys or caller-supplied identities."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / 'security/sigstore/policy.json'


def run(args):
    subprocess.run(args, check=True)


def settings():
    policy = json.loads(POLICY.read_text())
    trust, signing = [], []
    if policy['deployment'] == 'public':
        if policy.get('public_metadata_approved') is not True:
            raise ValueError('Public signing metadata disclosure has not been approved')
        # Cosign v3 authenticates public trust material through its embedded TUF root.
        signing = ['--use-signing-config=true']
    elif policy['deployment'] == 'private':
        # Exact, reviewed files in this checkout; never roots supplied with artifacts.
        root = ROOT / 'security/sigstore/trusted-root.json'
        config = ROOT / 'security/sigstore/signing-config.json'
        for path in (root, config):
            if not path.is_file() or not json.loads(path.read_text()):
                raise ValueError(f'Missing private Sigstore configuration: {path}')
        trust = ['--trusted-root', str(root)]
        signing = ['--signing-config', str(config)]
    else:
        raise ValueError('Select an approved public or private Sigstore deployment')
    return policy, trust, signing


def identity_flags(identity):
    for key in ('issuer', 'identity'):
        if not identity.get(key) or (key == 'issuer' and not identity[key].startswith('https://')):
            raise ValueError(f'Missing exact trusted {key}')
    return ['--certificate-oidc-issuer', identity['issuer'],
            '--certificate-identity', identity['identity']]


def image_policy(image, policy):
    match = re.fullmatch(r'([^\s@:]+(?:/[^\s@:]+)+)(?::[^\s@]+)?@sha256:[0-9a-f]{64}', image)
    if not match:
        raise ValueError('An immutable image reference with a SHA-256 digest is required')
    return policy['images'][match[1]]


def execute(operation, artifact):
    policy, trust, signing = settings()
    is_image = operation.endswith('image')
    identity = image_policy(artifact, policy) if is_image else policy
    flags = identity_flags(identity)
    if not is_image and (not Path(artifact).is_file() or Path(artifact).is_symlink()):
        raise ValueError('Artifact must be a regular file, not a symlink')
    bundle = artifact + '.sigstore.json'
    if operation.startswith('sign'):
        if os.environ.get('GITHUB_ACTIONS') != 'true':
            raise ValueError('Signing requires GitHub Actions OIDC')
        if os.environ.get('GITHUB_WORKFLOW_REF') != policy['identity'].removeprefix('https://github.com/'):
            raise ValueError('Signing workflow is not authorized by policy')
        # The supported provider requests the sigstore audience; never log or persist JWTs.
        args = ['cosign', 'sign' if is_image else 'sign-blob', '--yes',
                '--oidc-provider=github-actions', '--oidc-client-id=sigstore',
                *signing, *trust]
        if not is_image:
            args += ['--bundle', bundle]
        run([*args, artifact])
    args = ['cosign', 'verify' if is_image else 'verify-blob', *trust, *flags]
    if not is_image:
        if not Path(bundle).is_file():
            raise ValueError('Missing verification bundle')
        args += ['--bundle', bundle]
    # Defaults enforce certificate trust and transparency evidence. No insecure flags.
    run([*args, artifact])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['sign-file', 'verify-file', 'sign-image', 'verify-image'])
    parser.add_argument('artifact')
    args = parser.parse_args()
    execute(args.operation, args.artifact)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Artifact rejected: {error}')
