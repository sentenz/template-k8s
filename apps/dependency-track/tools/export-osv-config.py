#!/usr/bin/env python3
"""
Export the OSV vulnerability data source configuration (ecosystems + settings)
from a Dependency-Track instance to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-osv-config.py [--out osv-config-export.json]

The resulting JSON is consumed by import-osv-config.py to re-apply the same
OSV source configuration (e.g. ecosystems list) on another instance such as
Stage or Prod.

Note: the OSV source config lives on the v2 extension-point API, not the v1
config API:
  GET /api/v2/extension-points/vuln-data-source/extensions/osv/config
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("DTRACK_URL", "http://localhost:8080").rstrip("/")
TOKEN = os.environ.get("DTRACK_TOKEN") or os.environ.get("DTRACK_API_KEY")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

CONFIG_PATH = "/api/v2/extension-points/vuln-data-source/extensions/osv/config"


def auth_headers():
    # API keys (odt_ prefix) authenticate via X-Api-Key; session tokens via Bearer.
    if TOKEN.startswith("odt_"):
        return {"X-Api-Key": TOKEN, "Content-Type": "application/json"}
    return {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def get(path):
    r = urllib.request.Request(BASE + path, headers=auth_headers())
    try:
        return json.load(urllib.request.urlopen(r, context=CTX))
    except urllib.error.HTTPError as e:
        sys.exit(f"GET {path} -> {e.code}: {e.read().decode()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "osv-config-export.json"))
    args = ap.parse_args()
    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")

    raw = get(CONFIG_PATH)
    config = raw.get("config", raw) if isinstance(raw, dict) else raw

    ecosystems = config.get("ecosystems", [])
    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": os.environ.get("DTRACK_URL", "").rstrip("/"),
        "dataSource": "osv",
        "config": {
            "enabled": config.get("enabled"),
            "dataUrl": config.get("dataUrl"),
            "ecosystems": ecosystems,
            "aliasSyncEnabled": config.get("aliasSyncEnabled"),
            "incrementalMirroringEnabled": config.get("incrementalMirroringEnabled"),
        },
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Exported OSV config: enabled={out['config']['enabled']} "
          f"ecosystems={len(ecosystems)} -> {args.out}")
    print("Ecosystems: " + ", ".join(ecosystems))


if __name__ == "__main__":
    main()
