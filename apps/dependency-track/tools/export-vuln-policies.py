#!/usr/bin/env python3
"""
Export Dependency-Track vulnerability policies (v2 API) to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-vuln-policies.py [--out vuln-policies-export.json]

The resulting JSON is the declarative source of truth consumed by
import-vuln-policies.py to re-apply the same policies on another instance
(e.g. dev -> stage -> prod).

Each policy is exported with:
  - name, description, author
  - condition (CEL expression)
  - analysis (state, justification, vendor_response, details, suppress)
  - ratings (method, severity, vector, score)
  - operation_mode (DISABLED|APPLY|LOG), priority (0-100)
  - valid_from, valid_until
  - source (USER|BUNDLE)

Only USER-managed policies are re-applied by the importer; BUNDLE-managed
policies are exported for reference but skipped on import (they are read-only
and managed at the bundle source).

Note: requires an admin token (POLICY_MANAGEMENT or POLICY_MANAGEMENT_READ).
"""
import argparse
import os
import sys

import dtrack_common as dt


def list_all():
    """Page through /api/v2/vuln-policies and return all items."""
    items = []
    page_token = None
    while True:
        path = "/api/v2/vuln-policies?limit=1000"
        if page_token:
            path += f"&page_token={page_token}"
        body = dt.get(path)
        items.extend(body.get("items", []))
        page_token = body.get("next_page_token")
        if not page_token:
            break
    return items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=dt.default_out("vuln-policies-export.json"))
    args = ap.parse_args()
    dt.require_token()
    dt.check_auth()

    raw = list_all()
    policies = []
    for p in raw:
        policies.append({
            "name": p.get("name"),
            "description": p.get("description"),
            "author": p.get("author"),
            "condition": p.get("condition"),
            "analysis": p.get("analysis") or {},
            "ratings": p.get("ratings") or [],
            "operation_mode": p.get("operation_mode"),
            "priority": p.get("priority", 0),
            "valid_from": p.get("valid_from"),
            "valid_until": p.get("valid_until"),
            "source": p.get("source"),
        })

    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": dt.BASE,
        "policies": policies,
    }
    dt.write_json(args.out, out)
    user = sum(1 for p in policies if p["source"] == "USER")
    print(f"Exported {len(policies)} vulnerability policies "
          f"({user} user, {len(policies) - user} bundle) -> {args.out}")
    for p in policies:
        print(f"  - {p['name']}  (mode={p['operation_mode']}, priority={p['priority']}, "
              f"source={p['source']})")


if __name__ == "__main__":
    main()
