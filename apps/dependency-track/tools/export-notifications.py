#!/usr/bin/env python3
"""
Export Dependency-Track notification rules from an instance to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-notifications.py [--out notifications-export.json]

The resulting JSON is the declarative source of truth consumed by
import-notifications.py to re-apply the same rules on another instance
(e.g. dev -> stage -> prod).

Each rule is exported with:
  - name, scope (SYSTEM|PORTFOLIO), level (INFORMATIONAL|WARNING|ERROR)
  - enabled
  - notifyOn (notification group names, e.g. POLICY_VIOLATION)
  - publisher (by name, e.g. the built-in "Email" publisher)
  - projects and tags (by name)
  - config (the publisher-specific alert config parsed from the rule's
    publisherConfig JSON string, e.g. email recipientAddresses + subjectPrefix)

Note: requires an admin token (SYSTEM_CONFIGURATION).
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


def parse_publisher_config(raw):
    """The rule stores publisherConfig as a JSON string; parse it to a dict."""
    if not raw:
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw)
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "notifications-export.json"))
    args = ap.parse_args()
    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")

    raw_rules = get("/api/v1/notification/rule") or []

    rules = []
    for r in raw_rules:
        pub_name = (r.get("publisher") or {}).get("name")
        projects = [pr.get("name") for pr in (r.get("projects") or []) if pr.get("name")]
        tags = [t.get("name") for t in (r.get("tags") or []) if t.get("name")]
        rules.append({
            "name": r.get("name"),
            "scope": r.get("scope"),
            "level": r.get("notificationLevel"),
            "enabled": r.get("enabled", True),
            "notifyOn": sorted(r.get("notifyOn") or []),
            "publisher": pub_name,
            "projects": projects,
            "tags": tags,
            "config": parse_publisher_config(r.get("publisherConfig")),
        })

    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": os.environ.get("DTRACK_URL", "").rstrip("/"),
        "rules": rules,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Exported {len(rules)} rules -> {args.out}")
    for rule in rules:
        print(f"  rule: {rule['name']}  (scope={rule['scope']}, "
              f"notifyOn={rule['notifyOn']}, publisher={rule['publisher']})")


if __name__ == "__main__":
    main()
