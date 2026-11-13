#!/usr/bin/env python3
"""Verify a private snapshot before atomically installing firmware or another file."""
import importlib.util
from pathlib import Path
import os
import shutil
import sys
import tempfile

spec = importlib.util.spec_from_file_location('security', Path(__file__).with_name('artifact-security.py'))
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)


def install(source, destination):
    source, destination = Path(source), Path(destination)
    # Same filesystem gives atomic replacement; verification always covers installed bytes.
    with tempfile.TemporaryDirectory(prefix='.verified-', dir=destination.parent) as directory:
        snapshot = Path(directory) / 'artifact'
        shutil.copyfile(source, snapshot)
        shutil.copyfile(str(source) + '.sigstore.json', str(snapshot) + '.sigstore.json')
        security.execute('verify-file', str(snapshot))
        snapshot.chmod(0o644)
        os.replace(snapshot, destination)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: install-artifact.py SOURCE DESTINATION')
    install(*sys.argv[1:])
