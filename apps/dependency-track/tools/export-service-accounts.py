#!/usr/bin/env python3
"""
Export Dependency-Track service accounts (v2 API) to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-service-accounts.py [--out service-accounts-export.json]

The resulting JSON is the declarative source of truth consumed by
import-service-accounts.py to re-provision the same service accounts on
another instance (e.g. dev -> stage -> prod).

Each service account is exported with:
  - name, username (svc:<name>), email, suspended
  - permissions  (the account's EFFECTIVE permissions as reported by the v2
                 GET — on the deployed 5.2.x build this includes permissions
                 inherited from its teams, not just direct grants)
  - teams        (team names the account belongs to)
  - apiKeys      (metadata only: public_id, comment, created_at, last_used_at,
                 expires_at)

Because "permissions" is the effective set, the importer treats "teams" as the
source of truth for access by default (see import-service-accounts.py).

API keys are NOT re-exported. The plain-text key is returned by the API exactly
once at creation and is never stored (only its hash is), so it cannot be copied
between instances. The importer re-issues a fresh key per account when asked.

Note: requires an admin token (ACCESS_MANAGEMENT or ACCESS_MANAGEMENT_READ).
Tolerates pre-5.2.0 instances: if the /api/v2/service-accounts endpoint is
absent, the export writes an empty snapshot and exits 0.
"""
import argparse
import os
import sys

import dtrack_common as dt


def v2_available():
    st, _ = dt.req("GET", "/api/v2/service-accounts?limit=1")
    return st < 400


def list_all():
    """Page through /api/v2/service-accounts and return all items."""
    items = []
    page_token = None
    while True:
        path = "/api/v2/service-accounts?limit=500"
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
    ap.add_argument("--out", default=dt.default_out("service-accounts-export.json"))
    args = ap.parse_args()
    dt.require_token()
    dt.check_auth()

    if not v2_available():
        print("service-account API unavailable (pre-5.2.0 instance?) — writing empty snapshot",
              file=sys.stderr)
        accounts = []
    else:
        accounts = []
        for sa in list_all():
            name = sa.get("name")
            detail = dt.get(f"/api/v2/service-accounts/{name}")
            keys = dt.get(f"/api/v2/service-accounts/{name}/api-keys?limit=500")
            accounts.append({
                "name": name,
                "username": detail.get("username") or f"svc:{name}",
                "email": detail.get("email"),
                "suspended": bool(detail.get("suspended")),
                "permissions": sorted(detail.get("permissions") or []),
                "teams": sorted(t.get("name") for t in (detail.get("teams") or [])),
                "apiKeys": [{k: kk.get(k) for k in
                             ("public_id", "comment", "created_at", "last_used_at", "expires_at")}
                            for kk in (keys.get("items") or [])],
            })
        accounts.sort(key=lambda a: a["name"])

    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": dt.BASE,
        "serviceAccounts": accounts,
    }
    dt.write_json(args.out, out)
    print(f"Exported serviceAccounts={len(accounts)} -> {args.out}")


if __name__ == "__main__":
    main()
