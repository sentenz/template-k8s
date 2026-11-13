#!/usr/bin/env python3
"""Verify every rendered PodSpec image before applying the same manifest bytes."""
import importlib.util
from pathlib import Path
import sys
import yaml

spec = importlib.util.spec_from_file_location('security', Path(__file__).with_name('artifact-security.py'))
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)


def images(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ('containers', 'initContainers', 'ephemeralContainers'):
                for container in child:
                    yield container['image']
            else:
                yield from images(child)
    elif isinstance(value, list):
        for child in value:
            yield from images(child)


if __name__ == '__main__':
    manifests = list(yaml.safe_load_all(Path(sys.argv[1]).read_text()))
    refs = sorted(set(images(manifests)))
    if not refs:
        sys.exit('No workload images found; deployment rejected')
    for ref in refs:
        security.execute('verify-image', ref)
