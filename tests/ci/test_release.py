# SPDX-License-Identifier: Apache-2.0
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('latest', ROOT / 'scripts/ci/latest-release.py')
latest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latest)


class ReleaseTests(unittest.TestCase):
    def test_numeric_order_and_stable_only(self):
        self.assertEqual(latest.newest_stable(['1.9.0', '1.10.0', '2.0.0-beta.1', 'v9.0.0', '01.0.0']), '1.10.0')
        self.assertIsNone(latest.newest_stable(['invalid', '1.0.0+build']))

    def test_git_source_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin, work = root / 'origin', root / 'work'
            def git(path, *args):
                return subprocess.check_output(['git', '-C', str(path), *args], text=True, stderr=subprocess.DEVNULL).strip()
            origin.mkdir()
            git(origin, 'init', '-b', 'main')
            git(origin, 'config', 'user.email', 'test@example.com')
            git(origin, 'config', 'user.name', 'Test')
            git(origin, 'commit', '--allow-empty', '-m', 'initial')
            sha = git(origin, 'rev-parse', 'HEAD')
            git(origin, 'tag', '-a', '1.2.3', '-m', 'release')
            subprocess.run(['git', 'clone', '--depth=1', '--branch', '1.2.3', origin.as_uri(), str(work)], check=True, capture_output=True)
            env = dict(os.environ, GITHUB_REF_TYPE='tag', GITHUB_REF='refs/tags/1.2.3', RELEASE_VERSION='1.2.3', GITHUB_SHA=sha)
            def validate(**changes):
                return subprocess.run(['bash', str(ROOT / 'scripts/ci/validate-release.sh')], cwd=work, env=dict(env, **changes), capture_output=True).returncode
            self.assertEqual(validate(), 0)  # Annotated tag and shallow clone.
            self.assertNotEqual(validate(RELEASE_VERSION='01.2.3'), 0)
            self.assertNotEqual(validate(RELEASE_VERSION='1.2.4'), 0)
            self.assertNotEqual(validate(GITHUB_REF_TYPE='branch'), 0)
            git(origin, 'checkout', '-b', 'outside-main')
            git(origin, 'commit', '--allow-empty', '-m', 'unreleased')
            outside = git(origin, 'rev-parse', 'HEAD')
            git(origin, 'tag', '-f', '1.2.3')
            self.assertNotEqual(validate(), 0)  # Tag moved since event.
            git(work, 'fetch', 'origin', 'outside-main')
            git(work, 'checkout', outside)
            self.assertNotEqual(validate(GITHUB_SHA=outside), 0)  # Not on main.


if __name__ == '__main__':
    unittest.main()
