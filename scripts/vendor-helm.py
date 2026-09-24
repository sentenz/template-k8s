#!/usr/bin/env python3
"""Download and validate a chart without removing versions used by other targets."""

import argparse
import re
import subprocess
import tempfile
from pathlib import Path

import yaml


def vendor_chart(name, version, repository, directory, helm):
    for label, value in (("name", name), ("version", version)):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", value):
            raise ValueError(f"Invalid chart {label}: {value}")
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    target = root / f"{name}-{version}"
    if target.exists():
        raise ValueError(f"Immutable chart already exists: {target}; retain it unchanged")

    # Keep staging on the same filesystem so publishing is a directory rename.
    with tempfile.TemporaryDirectory(prefix=".download-", dir=root) as temporary:
        subprocess.run(
            [*helm, "pull", name, "--repo", repository, "--version", version,
             "--untar", "--untardir", temporary], check=True
        )
        chart_file = Path(temporary) / name / "Chart.yaml"
        metadata = yaml.safe_load(chart_file.read_text())
        if metadata.get("name") != name or str(metadata.get("version")) != version:
            raise ValueError(f"Downloaded chart metadata does not match {name}@{version}")
        Path(temporary).rename(target)
    print(f"Vendored {name}@{version} at {target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    parser.add_argument("version")
    parser.add_argument("repository")
    parser.add_argument("directory")
    parser.add_argument("helm", nargs=argparse.REMAINDER, help="Helm command, optionally a container invocation")
    args = parser.parse_args()
    try:
        vendor_chart(args.name, args.version, args.repository, args.directory, args.helm or ["helm"])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
