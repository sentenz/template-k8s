#!/usr/bin/env python3
"""Check vendored chart references and rendered environment invariants."""

import argparse
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


def check_vendor():
    count = 0
    for tree in ("apps", "platform"):
        for path in (ROOT / tree).rglob("kustomization.yaml"):
            config = yaml.safe_load(path.read_text()) or {}
            for chart in config.get("helmCharts", []):
                name, version = chart["name"], str(chart["version"])
                home = config["helmGlobals"]["chartHome"]
                metadata_path = path.parent / home / f"{name}-{version}" / name / "Chart.yaml"
                if not metadata_path.is_file():
                    raise ValueError(f"{path.relative_to(ROOT)}: missing vendored {name}@{version}")
                metadata = yaml.safe_load(metadata_path.read_text())
                if metadata.get("name") != name or str(metadata.get("version")) != version:
                    raise ValueError(f"Chart metadata mismatch: {metadata_path}")
                count += 1
    if not count:
        raise ValueError("No chart references found")
    print(f"Validated {count} vendored chart references")


def check_render(path, environment):
    resources = [item for item in yaml.safe_load_all(Path(path).read_text()) if item]
    if not resources:
        raise ValueError("Rendered manifest is empty")
    identities = set()
    namespaces = set()
    traefik_service = None
    traefik_deployment = None
    for resource in resources:
        metadata = resource["metadata"]
        identity = (resource["apiVersion"], resource["kind"], metadata.get("namespace"), metadata["name"])
        if identity in identities:
            raise ValueError(f"Duplicate resource: {identity}")
        identities.add(identity)
        if metadata.get("labels", {}).get("environment") != environment:
            raise ValueError(f"Incorrect environment label: {identity}")
        if resource["kind"] == "Namespace":
            namespaces.add(metadata["name"])
        if metadata.get("namespace") == "traefik" and metadata["name"] == "traefik":
            if resource["kind"] == "Service":
                traefik_service = resource
            elif resource["kind"] == "Deployment":
                traefik_deployment = resource
    if not {"dependency-track", "postgresql", "traefik"}.issubset(namespaces):
        raise ValueError("Expected namespaces are missing")
    expected_type = "NodePort" if environment == "dev" else "LoadBalancer"
    if not traefik_service or traefik_service["spec"].get("type") != expected_type:
        raise ValueError(f"Traefik Service must be {expected_type}")
    if environment == "dev":
        ports = {port["name"]: port.get("nodePort") for port in traefik_service["spec"]["ports"]}
        if ports.get("web") != 30080 or ports.get("websecure") != 30443:
            raise ValueError("Traefik NodePorts do not match Kind port mappings")
    if not traefik_deployment or traefik_deployment["spec"]["template"]["spec"].get("hostNetwork", False):
        raise ValueError("Traefik Deployment must not use host networking")
    print(f"Validated {len(resources)} resources for {environment}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rendered")
    parser.add_argument("--environment", choices=("dev", "stage", "prod"))
    args = parser.parse_args()
    try:
        check_vendor()
        if args.rendered:
            if not args.environment:
                parser.error("--rendered requires --environment")
            check_render(args.rendered, args.environment)
    except (ValueError, KeyError, OSError, yaml.YAMLError) as error:
        parser.exit(1, f"error: {error}\n")
