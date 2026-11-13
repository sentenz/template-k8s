"""Real Cosign verification against a public, upstream keyless release fixture."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

FIXTURES = Path(__file__).parent / 'fixtures'


@unittest.skipUnless(shutil.which('cosign'), 'Cosign v3 required for cryptographic tests')
class CryptoTests(unittest.TestCase):
    def verify(self, artifact, bundle, identity='keyless@projectsigstore.iam.gserviceaccount.com', issuer='https://accounts.google.com'):
        return subprocess.run([
            'cosign', 'verify-blob', str(artifact), '--bundle', str(bundle),
            '--certificate-identity', identity, '--certificate-oidc-issuer', issuer,
        ], capture_output=True, text=True)

    def test_valid_and_tampered_bundle(self):
        artifact = FIXTURES / 'cosign_checksums.txt'
        bundle = FIXTURES / 'cosign_checksums.txt.sigstore.json'
        valid = self.verify(artifact, bundle)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        with tempfile.TemporaryDirectory() as temporary:
            changed = Path(temporary) / 'changed'
            changed.write_bytes(artifact.read_bytes() + b'tampered')
            self.assertNotEqual(self.verify(changed, bundle).returncode, 0)
            data = json.loads(bundle.read_text())
            data['verificationMaterial']['tlogEntries'] = []
            changed.write_text(json.dumps(data))
            self.assertNotEqual(self.verify(artifact, changed).returncode, 0)
        self.assertNotEqual(self.verify(artifact, bundle, identity='unauthorized@example.com').returncode, 0)
        self.assertNotEqual(self.verify(artifact, bundle, issuer='https://invalid.example.com').returncode, 0)
