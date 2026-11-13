# SPDX-License-Identifier: Apache-2.0
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('manifest_images', ROOT / 'scripts/verify-manifest-images.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class ConsumerTests(unittest.TestCase):
    def test_nested_workloads_and_json_stream(self):
        image = 'ghcr.io/sentenz/k8s@sha256:' + 'a' * 64
        documents = [dict(spec=dict(template=dict(spec=dict(containers=[dict(image=image)],
            initContainers=[dict(image='ghcr.io/sentenz/k8s:unsigned')])))),
            dict(spec=dict(ephemeralContainers=[dict(image=image), dict(image='third.party/image:1')]))]
        text = '\n'.join(map(json.dumps, documents))
        self.assertEqual(manifest.owned_images(text, 'ghcr.io/sentenz/k8s'),
                         ['ghcr.io/sentenz/k8s:unsigned', image])

    def test_malformed_manifest_fails(self):
        with self.assertRaises(json.JSONDecodeError):
            manifest.owned_images('{invalid', 'ghcr.io/sentenz/k8s')

    def test_failed_verification_blocks_deployment_and_firmware_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for name, script in [('python3', '#!/bin/sh\ntouch "$VERIFIER_CALLED"\nexit 1\n'),
                                 ('kubectl', '#!/bin/sh\ntouch "$SENTINEL"\n')]:
                executable = directory / name
                executable.write_text(script)
                executable.chmod(0o755)
            env = dict(os.environ, PATH=str(directory) + ':' + os.environ['PATH'],
                       SENTINEL=str(directory / 'deployed'), TMPDIR=str(directory),
                       VERIFIER_CALLED=str(directory / 'verified'))
            deployment = subprocess.run(['bash', str(ROOT / 'scripts/deploy-verified-image.sh'),
                'ghcr.io/sentenz/k8s@sha256:' + 'a' * 64, 'ns', 'deployment', 'container'], env=env)
            self.assertNotEqual(deployment.returncode, 0)
            self.assertFalse((directory / 'deployed').exists())
            self.assertTrue((directory / 'verified').exists())
            (directory / 'verified').unlink()
            firmware = directory / 'firmware.bin'
            firmware.write_bytes(b'bad firmware')
            Path(str(firmware) + '.sigstore.json').write_text('{}')
            destination = directory / 'installed.bin'
            installation = subprocess.run(['bash', str(ROOT / 'scripts/install-verified-firmware.sh'),
                str(firmware), str(destination)], env=env)
            self.assertNotEqual(installation.returncode, 0)
            self.assertFalse(destination.exists())
            self.assertTrue((directory / 'verified').exists())


if __name__ == '__main__':
    unittest.main()
