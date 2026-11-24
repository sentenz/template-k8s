#!/usr/bin/env python3
"""
Idempotently apply Dependency-Track vulnerability policies (v2 API) defined in
vuln-policies-export.json to a target instance.

Usage:
  export DTRACK_URL=https://dependency-track.stage.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-vuln-policies.py --dry-run   # preview, no changes
  python3 import-vuln-policies.py             # apply

Each USER-managed policy in the JSON is reconciled against the target:
  - created if missing (POST /api/v2/vuln-policies)
  - replaced if present (PUT /api/v2/vuln-policies/{uuid})

BUNDLE-managed policies are skipped: they are read-only and managed at the
bundle source.

Notes:
  - "condition" is a CEL expression, compiled server-side. A compilation
    failure returns a 400 with structured error details.
  - "operation_mode" is DISABLED | APPLY | LOG.
  - "priority" is 0-100 (higher takes precedence).
  - "analysis.state" is EXPLOITABLE | IN_TRIAGE | FALSE_POSITIVE |
    NOT_AFFECTED | RESOLVED.
  - Requires an admin token (POLICY_MANAGEMENT).
"""
import argparse
import os
import sys

import dtrack_common as dt


def list_all():
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


def find_policy(name):
    for p in list_all():
        if p.get("name") == name:
            return p
    return None


def build_body(spec):
    body = {
        "name": spec["name"],
        "condition": spec["condition"],
        "analysis": spec.get("analysis") or {"state": "IN_TRIAGE"},
        "operation_mode": spec.get("operation_mode", "APPLY"),
        "priority": spec.get("priority", 0),
    }
    for opt in ("description", "author", "valid_from", "valid_until"):
        if spec.get(opt) is not None:
            body[opt] = spec[opt]
    if spec.get("ratings"):
        body["ratings"] = spec["ratings"]
    return body


def policies_equal(current, spec):
    """Compare the relevant fields of a live policy against the desired spec."""
    body = build_body(spec)
    for key in ("name", "condition", "operation_mode", "priority", "analysis"):
        if current.get(key) != body.get(key):
            return False
    if (current.get("description") or None) != (body.get("description") or None):
        return False
    if (current.get("author") or None) != (body.get("author") or None):
        return False
    if (current.get("ratings") or []) != (body.get("ratings") or []):
        return False
    return True


def apply_policy(spec):
    name = spec["name"]
    source = spec.get("source", "USER")
    if source != "USER":
        dt.log(f"skip policy '{name}' (source={source}, bundle-managed)")
        return

    existing = find_policy(name)
    if existing is None:
        dt.log(f"create policy '{name}' (mode={spec.get('operation_mode')}, "
               f"priority={spec.get('priority', 0)})")
        if not dt.DRY:
            st, res = dt.req("POST", "/api/v2/vuln-policies", build_body(spec))
            if st >= 400:
                sys.exit(f"error: failed to create policy '{name}': {st} {res}")
    else:
        if policies_equal(existing, spec):
            dt.log(f"policy '{name}' unchanged")
        else:
            dt.log(f"update policy '{name}'")
            if not dt.DRY:
                st, res = dt.req("PUT", f"/api/v2/vuln-policies/{existing['uuid']}", build_body(spec))
                if st >= 400:
                    sys.exit(f"error: failed to update policy '{name}': {st} {res}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=dt.default_out("vuln-policies-export.json"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    dt.DRY = args.dry_run

    dt.require_token()
    dt.check_auth()
    export = dt.read_json(args.export)
    policies = export.get("policies", [])

    dt.banner(dt.BASE, "DRY RUN" if dt.DRY else "LIVE",
              f"policies={len(policies)}")
    print(f"Source: {export.get('source')}")

    for spec in policies:
        print(f"\n== Policy: {spec['name']} ==")
        apply_policy(spec)

    if dt.DRY:
        print("\nDry run complete. No changes made.")


if __name__ == "__main__":
    main()
