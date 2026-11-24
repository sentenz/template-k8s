#!/usr/bin/env python3
"""
Export the full Dependency-Track portfolio (projects + hierarchy, teams,
permissions, ACLs, tags, managed users, and service accounts) to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-portfolio.py [--out portfolio-export.json]

The resulting JSON is consumed by import-portfolio.py.

Service accounts (5.2.0+) are exported from the v2 API. Their API keys are
exported as metadata only (public_id, comment, created_at, expires_at) — the
plain-text key is returned by the API exactly once at creation and is never
stored, so it cannot be re-exported. Re-issue keys on the target with
import-portfolio.py --service-accounts.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("DTRACK_URL", "http://localhost:8080").rstrip("/") + "/api/v1"
BASE2 = os.environ.get("DTRACK_URL", "http://localhost:8080").rstrip("/") + "/api/v2"
TOKEN = os.environ.get("DTRACK_TOKEN") or os.environ.get("DTRACK_API_KEY")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def auth_headers():
    # API keys (odt_ prefix) authenticate via X-Api-Key; session tokens via Bearer.
    if TOKEN.startswith("odt_"):
        return {"X-Api-Key": TOKEN}
    return {"Authorization": f"Bearer {TOKEN}"}


def _get(base, path):
    r = urllib.request.Request(base + path, headers=auth_headers())
    try:
        return json.load(urllib.request.urlopen(r, context=CTX))
    except urllib.error.HTTPError as e:
        sys.exit(f"GET {path} -> {e.code}: {e.read().decode()}")


def get(path):
    return _get(BASE, path)


def get2(path):
    return _get(BASE2, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "portfolio-export.json"))
    args = ap.parse_args()
    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")

    projects, page = [], 1
    while True:
        batch = get(f"/project?pageSize=500&page={page}")
        if not batch:
            break
        projects += batch
        if len(batch) < 500:
            break
        page += 1

    teams = get("/team?pageSize=500")
    for t in teams:
        t["aclProjects"] = get(f"/acl/team/{t['uuid']}")

    tag_names = sorted(set(tg["name"] for tg in get("/tag?pageSize=500")))
    tag_projects = {n: [] for n in tag_names}
    for p in projects:
        for tg in (p.get("tags") or []):
            if tg["name"] in tag_projects:
                tag_projects[tg["name"]].append({"name": p["name"], "version": p.get("version")})

    users = get("/user/managed?pageSize=500")

    # Service accounts (5.2.0+, v2 API). Tolerate older instances that lack the
    # endpoint so the rest of the export still succeeds.
    service_accounts = []
    try:
        page, token = 1, None
        while True:
            url = "/service-accounts?limit=500"
            if token:
                url += f"&page_token={token}"
            batch = get2(url)
            items = batch.get("items", batch if isinstance(batch, list) else [])
            service_accounts += items
            token = batch.get("next_page_token") if isinstance(batch, dict) else None
            if not token or not items:
                break
            page += 1
    except SystemExit:
        print("  !! service-account export unavailable (pre-5.2.0 instance?) — skipping", file=sys.stderr)

    # Attach each service account's direct permissions + API-key metadata.
    for sa in service_accounts:
        name = sa.get("name")
        if not name:
            continue
        try:
            detail = get2(f"/service-accounts/{name}")
            sa["permissions"] = detail.get("permissions", [])
            sa["teams"] = detail.get("teams", [])
        except SystemExit:
            sa["permissions"], sa["teams"] = [], []
        try:
            keys = get2(f"/service-accounts/{name}/api-keys?limit=500")
            key_items = keys.get("items", keys if isinstance(keys, list) else [])
            sa["apiKeys"] = [{k: kk.get(k) for k in
                              ("public_id", "comment", "created_at", "last_used_at", "expires_at")}
                             for kk in key_items]
        except SystemExit:
            sa["apiKeys"] = []

    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": os.environ.get("DTRACK_URL", "").rstrip("/"),
        "projects": [{k: p.get(k) for k in
                      ("uuid", "name", "version", "classifier", "collectionLogic",
                       "isLatest", "active", "parent", "tags")} for p in projects],
        "teams": [{k: t.get(k) for k in ("uuid", "name", "permissions", "aclProjects")} for t in teams],
        "tags": [{"name": n, "projects": tag_projects[n]} for n in tag_names],
        "users": [{k: u.get(k) for k in ("username", "fullname", "email", "teams", "suspended")} for u in users],
        "serviceAccounts": [{k: sa.get(k) for k in
                             ("name", "username", "email", "suspended", "permissions", "teams", "apiKeys")}
                            for sa in service_accounts],
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Exported projects={len(projects)} teams={len(teams)} "
          f"tags={len(tag_names)} users={len(users)} serviceAccounts={len(service_accounts)} -> {args.out}")


if __name__ == "__main__":
    main()
