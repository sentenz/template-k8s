#!/usr/bin/env python3
"""
Create a service account for each automation (CI) team in the portfolio.

For every team whose name ends in the given suffix (default `-ci`), this creates
a service account named after the team (username `svc:<team>`), adds it as a
member of that team, and issues one API key.

Why team membership: project ACLs can only be assigned to teams, so the service
account must belong to the CI team to inherit its ACL scope. Membership also
grants the team's permissions (e.g. BOM_UPLOAD), so no direct permissions are
needed. The result is a distinct, suspendable identity per pipeline with the
exact scope the team already has — the recommended migration off shared team
API keys.

Idempotent: existing service accounts are left in place. Use --rotate to
re-issue their API keys.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<admin-api-token>          # or DTRACK_API_KEY
  python3 create-service-accounts.py --dry-run   # preview, no changes
  python3 create-service-accounts.py             # create + issue keys
  python3 create-service-accounts.py --rotate    # also re-issue existing keys

The plain-text API key is printed exactly once to stderr — capture it into the
CI secret store immediately; it cannot be retrieved afterwards.
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

DRY = False


def auth_headers():
    # API keys (odt_ prefix) authenticate via X-Api-Key; session tokens via Bearer.
    if TOKEN.startswith("odt_"):
        return {"X-Api-Key": TOKEN, "Content-Type": "application/json"}
    return {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def req(method, path, body=None, base=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request((base or BASE) + path, data=data, method=method, headers=auth_headers())
    try:
        resp = urllib.request.urlopen(r, context=CTX)
        raw = resp.read().decode()
        return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw


def get(path, base=None):
    st, body = req("GET", path, base=base)
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        raise RuntimeError(f"GET {path} -> {st}: {body}")
    return body


def log(msg):
    print(f"  [{'DRY' if DRY else 'OK '}] {msg}")


def list_service_accounts():
    out, token = [], None
    while True:
        url = "/service-accounts?limit=500"
        if token:
            url += f"&page_token={token}"
        batch = get(url, base=BASE2)
        items = batch.get("items", batch if isinstance(batch, list) else [])
        out += items
        token = batch.get("next_page_token") if isinstance(batch, dict) else None
        if not token or not items:
            break
    return out


def issue_key(name, comment):
    st, res = req("POST", f"/service-accounts/{name}/api-keys",
                  {"comment": comment, "expires_in_days": EXPIRES_DAYS}, base=BASE2)
    if st >= 400:
        print(f"  !! API key issue failed for {name}: {st} {res}", file=sys.stderr)
        return
    print(f"  !! NEW API KEY svc:{name}: {res.get('key')} "
          f"(public_id={res.get('public_id')}, expires={res.get('expires_at')}) — capture now",
          file=sys.stderr)


def main():
    global DRY, EXPIRES_DAYS
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--rotate", action="store_true",
                    help="re-issue API keys for service accounts that already exist")
    ap.add_argument("--suffix", default="-ci",
                    help="team name suffix treated as automation (default: -ci)")
    ap.add_argument("--expires-in-days", type=int, default=365,
                    help="API key lifetime in days (max 366; default 365)")
    args = ap.parse_args()
    DRY = args.dry_run
    EXPIRES_DAYS = args.expires_in_days

    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")

    teams = get("/team?pageSize=500")
    ci_teams = [t for t in teams if t["name"].endswith(args.suffix)]
    if not ci_teams:
        print(f"No teams ending in '{args.suffix}' found. Nothing to do.")
        return

    existing = {sa["name"]: sa for sa in list_service_accounts()}

    print(f"Target: {BASE}  ({'DRY RUN' if DRY else 'LIVE'})")
    print(f"Automation teams ('{args.suffix}'): {len(ci_teams)}   "
          f"existing service accounts: {len(existing)}\n")

    created = skipped = 0
    for t in sorted(ci_teams, key=lambda x: x["name"]):
        name = t["name"]
        username = f"svc:{name}"
        team_uuid = t["uuid"]
        perms = sorted(p["name"] if isinstance(p, dict) else p for p in (t.get("permissions") or []))

        if name in existing:
            if args.rotate:
                if DRY:
                    log(f"service-account exists, would re-issue key: {username}")
                else:
                    issue_key(name, "reissued by create-service-accounts")
            else:
                log(f"service-account exists, skipping (use --rotate to re-issue key): {username}")
            skipped += 1
            continue

        if DRY:
            log(f"create service-account {username} -> team '{name}' (ACL scope) "
                f"+ direct perms {perms} + API key")
            created += 1
            continue

        st, res = req("POST", "/service-accounts",
                      {"name": name, "email": f"{name}@example.com"}, base=BASE2)
        if st >= 400:
            print(f"  !! create failed {username}: {st} {res}", file=sys.stderr)
            continue

        # Membership: exactly this team (grants ACL scope only — the team is a
        # pure access team).
        st, res = req("PUT", "/user/membership", {"username": username, "teams": [team_uuid]})
        if st >= 400:
            print(f"  !! membership failed {username}: {st} {res}", file=sys.stderr)

        # Permissions are granted DIRECTLY to the service account (recommended
        # pattern: capabilities on the identity, scope on the team).
        for p in perms:
            req("POST", f"/permission/{p}/user/{username}")

        issue_key(name, f"created for team {name}")
        log(f"created service-account {username} -> team '{name}' + direct perms {perms}")
        created += 1

    print(f"\nDone. created={created} skipped={skipped}")
    if not DRY and created:
        print("Re-run `make dtrack-export` to record the new service accounts in portfolio-export.json.")


if __name__ == "__main__":
    main()
