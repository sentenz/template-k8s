import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


security = load('security', 'artifact-security.py')
deployment = load('deployment', 'verify-deployment.py')
installer = load('installer', 'install-artifact.py')


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.artifact = self.directory / 'firmware.bin'
        self.artifact.write_bytes(b'firmware')
        self.policy = json.loads(security.POLICY.read_text())
        self.settings = patch.object(security, 'settings', return_value=(self.policy, [], []))
        self.settings.start()
        self.addCleanup(self.settings.stop)

    def bundle(self):
        Path(str(self.artifact) + '.sigstore.json').write_text('{}')

    def test_missing_bundle_rejected(self):
        with patch.object(security, 'run') as run, self.assertRaises(ValueError):
            security.execute('verify-file', str(self.artifact))
        run.assert_not_called()

    def test_mutable_and_unapproved_images_rejected(self):
        for image in ['ghcr.io/sentenz/k8s:latest', 'evil.io/k8s@sha256:' + 'a'*64]:
            with self.subTest(image=image), self.assertRaises((ValueError, KeyError)):
                security.execute('verify-image', image)

    def test_exact_identity_and_issuer_enforced(self):
        with patch.object(security, 'run') as run:
            security.execute('verify-image', 'ghcr.io/sentenz/k8s@sha256:' + 'a'*64)
        command = run.call_args.args[0]
        self.assertIn(self.policy['identity'], command)
        self.assertIn(self.policy['issuer'], command)
        self.assertFalse(any('ignore' in flag or 'regexp' in flag for flag in command))

    def test_verifier_failure_propagates(self):
        self.bundle()
        with patch.object(security, 'run', side_effect=subprocess.CalledProcessError(1, 'cosign')):
            with self.assertRaises(subprocess.CalledProcessError):
                security.execute('verify-file', str(self.artifact))

    def test_signer_must_be_approved_workflow(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_WORKFLOW_REF': 'evil/repo/workflow@refs/heads/main'}):
            with self.assertRaises(ValueError):
                security.execute('sign-file', str(self.artifact))

    def test_supported_oidc_provider_and_verification_after_sign(self):
        self.bundle()
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_WORKFLOW_REF': self.policy['identity'].removeprefix('https://github.com/')}):
            with patch.object(security, 'run') as run:
                security.execute('sign-file', str(self.artifact))
        self.assertEqual(run.call_count, 2)
        self.assertIn('--oidc-provider=github-actions', run.call_args_list[0].args[0])
        self.assertIn('--oidc-client-id=sigstore', run.call_args_list[0].args[0])
        self.assertEqual(run.call_args_list[1].args[0][1], 'verify-blob')

    def test_all_container_types_and_lists_checked(self):
        manifests = [{'kind': 'List', 'items': [{'spec': {'template': {'spec': {
            'containers': [{'image': 'app'}], 'initContainers': [{'image': 'init'}],
            'ephemeralContainers': [{'image': 'debug'}]}}}}]}]
        self.assertEqual(set(deployment.images(manifests)), {'app', 'init', 'debug'})

    def test_install_failure_preserves_destination(self):
        self.bundle()
        destination = self.directory / 'installed.bin'
        destination.write_bytes(b'previous')
        with patch.object(installer.security, 'execute', side_effect=ValueError('invalid signature')):
            with self.assertRaises(ValueError):
                installer.install(self.artifact, destination)
        self.assertEqual(destination.read_bytes(), b'previous')

    def test_install_uses_verified_snapshot(self):
        self.bundle()
        destination = self.directory / 'installed.bin'
        def verify(operation, snapshot):
            self.assertEqual(operation, 'verify-file')
            self.assertEqual(Path(snapshot).read_bytes(), b'firmware')
            self.artifact.write_bytes(b'changed-after-verification')
        with patch.object(installer.security, 'execute', side_effect=verify):
            installer.install(self.artifact, destination)
        self.assertEqual(destination.read_bytes(), b'firmware')

    def test_private_missing_roots_and_public_disclosure_rejected(self):
        self.settings.stop()
        policy_path = self.directory / 'policy.json'
        with patch.object(security, 'POLICY', policy_path), patch.object(security, 'ROOT', self.directory):
            for policy in [{'deployment': 'private'}, {'deployment': 'public', 'public_metadata_approved': False}, {'deployment': 'unknown'}]:
                policy_path.write_text(json.dumps(policy))
                with self.assertRaises(ValueError):
                    security.settings()


if __name__ == '__main__':
    unittest.main()
