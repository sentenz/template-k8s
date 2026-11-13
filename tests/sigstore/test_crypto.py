# SPDX-License-Identifier: Apache-2.0
"""Optional real Cosign tests; fixture is the upstream v3.1.4 release and bundle."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('signer_crypto', ROOT / '.github/actions/sigstore/sigstore.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


@unittest.skipUnless(os.environ.get('COSIGN_TEST_BLOB') and os.environ.get('COSIGN_TEST_BUNDLE'),
                     'Set COSIGN_TEST_BLOB and COSIGN_TEST_BUNDLE for real cryptographic tests')
class CryptoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temp.name)
        cls.blob = cls.directory / 'cosign.bin'
        cls.blob.write_bytes(Path(os.environ['COSIGN_TEST_BLOB']).read_bytes())
        cls.bundle = Path(os.environ['COSIGN_TEST_BUNDLE']).read_text()
        cache = cls.directory / 'tuf'
        env = {k: v for k, v in os.environ.items() if not k.startswith(('COSIGN_', 'SIGSTORE_', 'TUF_'))}
        env['TUF_ROOT'] = str(cache)
        subprocess.run(['cosign', 'initialize'], check=True, env=env)
        root = next(cache.rglob('trusted_root.json'))
        cls.policy_base = dict(deployment='private', issuer='https://accounts.google.com',
            trusted_root={'path': str(root), 'sha256': hashlib.sha256(root.read_bytes()).hexdigest()},
            identities={'firmware': ['keyless@projectsigstore.iam.gserviceaccount.com']})

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.policy = copy.deepcopy(self.policy_base)
        self.path = self.directory / 'policy.json'
        self.args = argparse.Namespace(operation='verify', kind='firmware', identity=self.policy['identities']['firmware'][0],
            policy=str(self.path), files=str(self.blob), image='', bundle='', release_version='')
        Path(str(self.blob) + '.sigstore.json').write_text(self.bundle)

    def verify(self):
        self.path.write_text(json.dumps(self.policy))
        signer.execute(self.args)

    def test_valid_keyless_signature(self):
        self.verify()

    def test_changed_artifact(self):
        tampered = self.directory / 'tampered.bin'
        tampered.write_bytes(b'tampered firmware')
        Path(str(tampered) + '.sigstore.json').write_text(self.bundle)
        self.args.files = str(tampered)
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_wrong_certificate_identity(self):
        self.args.identity = 'unauthorized@example.com'
        self.policy['identities']['firmware'] = [self.args.identity]
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_wrong_oidc_issuer(self):
        self.policy['issuer'] = 'https://token.actions.githubusercontent.com'
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_missing_transparency_evidence(self):
        bundle = json.loads(self.bundle)
        bundle['verificationMaterial']['tlogEntries'] = []
        Path(str(self.blob) + '.sigstore.json').write_text(json.dumps(bundle))
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_changed_certificate(self):
        bundle = json.loads(self.bundle)
        certificate = bundle['verificationMaterial']['certificate']['rawBytes']
        bundle['verificationMaterial']['certificate']['rawBytes'] = 'AAAA' + certificate[4:]
        Path(str(self.blob) + '.sigstore.json').write_text(json.dumps(bundle))
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()


if __name__ == '__main__':
    unittest.main()
