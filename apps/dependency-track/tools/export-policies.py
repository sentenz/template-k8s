#!/usr/bin/env python3
"""
Export Dependency-Track policies from an instance to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-policies.py [--out policies-export.json]

The resulting JSON is the declarative source of truth consumed by
import-policies.py to re-apply the same policies on another instance
(e.g. dev -> stage -> prod).

Each policy is exported with:
  - name, operator (ALL|ANY), violationState (INFO|WARN|FAIL)
  - includeChildren, onlyLatestProjectVersion
  - conditions (subject, operator, value)
  - projects and tags (by name)

Note: requires an admin token (POLICY_MANAGEMENT or POLICY_MANAGEMENT_READ).
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
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "policies-export.json"))
    args = ap.parse_args()
    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")

    raw = get("/api/v1/policy?pageSize=1000") or []

    policies = []
    for p in raw:
        conditions = [
            {
                "subject": c.get("subject"),
                "operator": c.get("operator"),
                "value": c.get("value"),
            }
            for c in (p.get("policyConditions") or [])
        ]
        projects = [pr.get("name") for pr in (p.get("projects") or []) if pr.get("name")]
        tags = [t.get("name") for t in (p.get("tags") or []) if t.get("name")]
        policies.append({
            "name": p.get("name"),
            "operator": p.get("operator"),
            "violationState": p.get("violationState"),
            "includeChildren": p.get("includeChildren", False),
            "onlyLatestProjectVersion": p.get("onlyLatestProjectVersion", False),
            "projects": projects,
            "tags": tags,
            "conditions": conditions,
        })

    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": os.environ.get("DTRACK_URL", "").rstrip("/"),
        "policies": policies,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Exported {len(policies)} policies -> {args.out}")
    for pol in policies:
        print(f"  - {pol['name']}  (operator={pol['operator']}, "
              f"state={pol['violationState']}, conditions={len(pol['conditions'])})")


if __name__ == "__main__":
    main()
