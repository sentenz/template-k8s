# SPDX-License-Identifier: Apache-2.0
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signer = load('signer', ROOT / '.github/actions/sigstore/sigstore.py')
release = load('release', ROOT / '.github/actions/sigstore/release.py')


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.policy = json.loads((ROOT / '.github/sigstore/policy.json').read_text())
        self.policy_path = self.dir / 'policy.json'
        self.blob = self.dir / 'firmware.bin'
        self.blob.write_bytes(b'firmware')
        Path(str(self.blob) + '.sigstore.json').write_text('{}')
        self.args = argparse.Namespace(operation='verify', kind='firmware',
            identity=self.policy['identities']['firmware'][0], policy=str(self.policy_path),
            image='', files=str(self.blob), bundle=str(self.dir / 'image.sigstore.json'),
            release_version='')
        self.write_policy()

    def write_policy(self):
        self.policy_path.write_text(json.dumps(self.policy))

    def valid_signing_env(self):
        return dict(GITHUB_ACTIONS='true', GITHUB_REPOSITORY='sentenz/template-k8s',
                    GITHUB_REF='refs/heads/main', GITHUB_EVENT_NAME='push',
                    ACTIONS_ID_TOKEN_REQUEST_URL='https://example.test?x=1',
                    ACTIONS_ID_TOKEN_REQUEST_TOKEN='test-token')

    def image(self):
        self.args.kind = 'image'
        self.args.identity = self.policy['identities']['image'][0]
        self.args.files = ''
        self.args.image = 'ghcr.io/sentenz/k8s@sha256:' + 'a' * 64

    def test_valid_blob(self):
        signer.validate(self.args)

    def test_unauthorized_identity(self):
        for identity in ('https://github.com/attacker/repo/.github/workflows/docker.yml@refs/heads/main',
                         self.args.identity.replace('main', 'feature'), '.*'):
            with self.subTest(identity=identity):
                self.args.identity = identity
                with self.assertRaises(ValueError):
                    signer.validate(self.args)

    def test_wrong_artifact_identity(self):
        self.args.identity = self.policy['identities']['image'][0]
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_missing_empty_duplicate_files(self):
        for files in ('', str(self.dir / 'missing.bin'), str(self.blob) + '\n' + str(self.blob)):
            with self.subTest(files=files):
                self.args.files = files
                with self.assertRaises(ValueError):
                    signer.validate(self.args)

    def test_empty_artifact(self):
        self.blob.write_bytes(b'')
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_missing_bundle(self):
        Path(str(self.blob) + '.sigstore.json').unlink()
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_symlink_bundle(self):
        path = Path(str(self.blob) + '.sigstore.json')
        path.unlink()
        path.symlink_to(self.blob)
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_mutable_or_foreign_image(self):
        self.image()
        for image in ('ghcr.io/sentenz/k8s:latest', 'ghcr.io/evil/k8s@sha256:' + 'a' * 64,
                      'ghcr.io/sentenz/k8s@sha256:abc', 'ghcr.io/sentenz/k8s@sha256:' + 'a' * 64 + '\n'):
            with self.subTest(image=image):
                self.args.image = image
                with self.assertRaises(ValueError):
                    signer.validate(self.args)

    def test_tag_and_digest_normalizes_to_digest(self):
        self.image()
        self.args.image = self.args.image.replace('k8s@', 'k8s:1.2.3@')
        signer.validate(self.args)
        self.assertNotIn(':1.2.3', self.args.image)

    def test_private_registry_port_is_preserved(self):
        self.image()
        self.policy['image_repository'] = 'registry.internal:5443/team/k8s'
        self.write_policy()
        self.args.image = self.policy['image_repository'] + ':1.2.3@sha256:' + 'a' * 64
        signer.validate(self.args)
        self.assertEqual(self.args.image, self.policy['image_repository'] + '@sha256:' + 'a' * 64)

    def test_public_disclosure_requires_opt_in(self):
        self.policy['public_metadata_permitted'] = False
        self.write_policy()
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_public_cannot_override_trust(self):
        self.policy['trusted_root'] = {'path': 'root.json'}
        self.write_policy()
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_private_requires_explicit_trust(self):
        self.policy['deployment'] = 'private'
        self.write_policy()
        with self.assertRaises(KeyError):
            signer.validate(self.args)

    def test_private_trust_digest_and_log_requirements(self):
        self.policy['deployment'] = 'private'
        root = self.dir / 'trusted-root.json'
        root.write_text(json.dumps({'certificateAuthorities': [{}], 'ctlogs': [{}], 'tlogs': [{}]}))
        self.policy['trusted_root'] = {'path': root.name, 'sha256': hashlib.sha256(root.read_bytes()).hexdigest()}
        self.write_policy()
        signer.validate(self.args)
        root.write_text('{}')
        with self.assertRaises(ValueError):
            signer.validate(self.args)
        self.policy['trusted_root']['sha256'] = hashlib.sha256(root.read_bytes()).hexdigest()
        self.write_policy()
        with self.assertRaises(ValueError):
            signer.validate(self.args)

    def test_signing_rejects_untrusted_contexts(self):
        self.args.operation = 'sign'
        for key, value in [('GITHUB_ACTIONS', ''), ('GITHUB_REPOSITORY', 'evil/repo'),
                           ('GITHUB_REF', 'refs/pull/1/merge'), ('GITHUB_EVENT_NAME', 'pull_request_target'),
                           ('ACTIONS_ID_TOKEN_REQUEST_TOKEN', '')]:
            with self.subTest(key=key):
                env = self.valid_signing_env()
                env[key] = value
                with patch.dict(os.environ, env, clear=True), self.assertRaises(ValueError):
                    signer.validate(self.args)

    def test_signing_uses_github_provider_and_sigstore_audience(self):
        self.args.operation = 'sign'
        calls = []
        def fake(command, **kwargs):
            calls.append(command)
            if command[1] == 'version':
                return subprocess.CompletedProcess(command, 0, json.dumps({'gitVersion': signer.VERSION}))
            if command[1] == 'initialize':
                Path(kwargs['env']['TUF_ROOT'], 'trusted_root.json').write_text('{}')
            return subprocess.CompletedProcess(command, 0)
        with patch.dict(os.environ, self.valid_signing_env(), clear=True), patch.object(signer.subprocess, 'run', side_effect=fake):
            signer.execute(self.args)
        sign = next(call for call in calls if call[1] == 'sign-blob')
        self.assertEqual(sign[sign.index('--oidc-provider') + 1], 'github-actions')
        self.assertEqual(sign[sign.index('--oidc-client-id') + 1], 'sigstore')
        self.assertEqual(calls[-1][1], 'verify-blob')
        self.assertFalse(any('--key' in call or '--insecure-ignore-tlog' in call for call in calls))

    def test_crypto_failure_propagates_and_stops_batch(self):
        other = self.dir / 'other.bin'
        other.write_bytes(b'other')
        Path(str(other) + '.sigstore.json').write_text('{}')
        self.args.files += '\n' + str(other)
        calls = []
        def fake(command, **kwargs):
            calls.append(command)
            if command[1] == 'version':
                return subprocess.CompletedProcess(command, 0, json.dumps({'gitVersion': signer.VERSION}))
            if command[1] == 'initialize':
                Path(kwargs['env']['TUF_ROOT'], 'trusted_root.json').write_text('{}')
            if command[1] == 'verify-blob':
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(signer.subprocess, 'run', side_effect=fake), self.assertRaises(subprocess.CalledProcessError):
            signer.execute(self.args)
        self.assertEqual(sum(call[1] == 'verify-blob' for call in calls), 1)

    def test_release_inventory_rejects_missing_extra_and_changed_assets(self):
        original = Path.cwd()
        os.chdir(self.dir)
        self.addCleanup(os.chdir, original)
        for name in release.ARTIFACTS:
            Path(name).write_text(name)
        release.create('1.2.3', 'a' * 40)
        for name in (*release.ARTIFACTS, 'release-manifest.json'):
            Path(name + '.sigstore.json').write_text('{}')
        Path('image-reference.txt').write_text('ghcr.io/sentenz/k8s@sha256:' + 'a' * 64)
        Path('image.sigstore.json').write_text('{}')
        # The test policy and firmware files aren't release assets.
        self.policy_path.unlink()
        self.blob.unlink()
        Path(str(self.blob) + '.sigstore.json').unlink()
        release.verify('1.2.3', self.dir)
        with self.assertRaises(ValueError):
            release.verify('1.2.4', self.dir)
        Path('unsigned.bin').write_text('unexpected')
        with self.assertRaises(ValueError):
            release.verify('1.2.3', self.dir)
        Path('unsigned.bin').unlink()
        Path('source.zip').write_text('tampered')
        with self.assertRaises(ValueError):
            release.verify('1.2.3', self.dir)


if __name__ == '__main__':
    unittest.main()
