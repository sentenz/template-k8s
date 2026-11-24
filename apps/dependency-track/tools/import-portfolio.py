#!/usr/bin/env python3
"""
Idempotent Dependency-Track portfolio importer.

Imports projects (hierarchy), teams, permissions, ACLs, and tags described in
portfolio-export.json into a target Dependency-Track instance.

Usage:
  export DTRACK_URL=https://dependency-track.prod.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-portfolio.py --dry-run    # preview, no changes
  python3 import-portfolio.py              # apply
  python3 import-portfolio.py --users users.json   # also create managed users
                                           # users.json: [{"username":..,"password":..}, ...]
  python3 import-portfolio.py --service-accounts   # also create/reconcile service accounts
                                           # (5.2.0+). Re-issues one API key per account.

Notes:
  - Safe to re-run: existing projects/teams/tags are updated, not duplicated.
  - Projects are matched by (name, version); teams by name; tags by name.
  - ACLs and permissions are reconciled (added/removed) to match the export.
  - Managed users are NOT created unless --users is given (passwords are not
    part of the export). Existing users' memberships are reconciled.
  - Service accounts are NOT created unless --service-accounts is given. When
    applied, each account is (re)created with its direct permissions and team
    memberships, and a fresh API key is issued. The plain-text key is printed
    once and must be captured — it cannot be retrieved afterwards.
  - Requires an admin token (ACCESS_MANAGEMENT / PORTFOLIO_MANAGEMENT).
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
stats = {"created": 0, "updated": 0, "unchanged": 0, "skipped": 0}


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


def check_auth():
    st, _ = req("GET", "/team?pageSize=1")
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        sys.exit(f"error: cannot reach {BASE} ({st}). Check DTRACK_URL.")


def log(msg):
    print(f"  [{'DRY' if DRY else 'OK '}] {msg}")


def perm_names(p):
    return sorted(x["name"] if isinstance(x, dict) else x for x in (p or []))


# ---------------------------------------------------------------- projects
def load_projects():
    out, page = [], 1
    while True:
        batch = get(f"/project?pageSize=500&page={page}")
        if not batch:
            break
        out += batch
        if len(batch) < 500:
            break
        page += 1
    return out


def import_projects(export):
    existing = {(p["name"], p.get("version")): p for p in load_projects()}
    by_key = {(p["name"], p.get("version")): p for p in export["projects"]}
    ordered, seen = [], set()

    def visit(p, stack):
        key = (p["name"], p.get("version"))
        if key in seen:
            return
        par = p.get("parent")
        if par:
            pkey = (par["name"], None)
            if pkey in by_key and pkey not in stack:
                visit(by_key[pkey], stack | {key})
        seen.add(key)
        ordered.append(p)

    for p in export["projects"]:
        visit(p, set())

    new_existing = {}
    for p in ordered:
        name, ver = p["name"], p.get("version")
        par = p.get("parent")
        parent_uuid = new_existing.get((par["name"], None)) if par else None
        body = {"name": name, "active": p.get("active", True)}
        if ver is not None:
            body["version"] = ver
            body["classifier"] = p.get("classifier") or "APPLICATION"
            body["isLatest"] = bool(p.get("isLatest"))
        if p.get("collectionLogic"):
            body["collectionLogic"] = p["collectionLogic"]
        if parent_uuid:
            body["parent"] = {"uuid": parent_uuid}

        key = (name, ver)
        if key in existing:
            body["uuid"] = existing[key]["uuid"]
            if DRY:
                log(f"project update: {name} v={ver}")
            else:
                st, _ = req("POST", "/project", body)
                if st >= 400:
                    print(f"  !! project update failed {name} v={ver}: {st}", file=sys.stderr)
                else:
                    stats["updated"] += 1
                    log(f"project update: {name} v={ver}")
        else:
            if DRY:
                log(f"project create: {name} v={ver} parent={par['name'] if par else '-'}")
                stats["created"] += 1
            else:
                st, res = req("PUT", "/project", body)
                if st >= 400:
                    print(f"  !! project create failed {name} v={ver}: {st} {res}", file=sys.stderr)
                    continue
                stats["created"] += 1
                log(f"project create: {name} v={ver} -> {res['uuid'][:8]}")
        new_existing[key] = body.get("uuid") or (res["uuid"] if not DRY else None)
    return new_existing


# ------------------------------------------------------------------- teams
def reconcile_acl(team_uuid, want_uuids):
    have = {p["uuid"] for p in get(f"/acl/team/{team_uuid}")}
    for u in want_uuids:
        if u not in have:
            req("PUT", "/acl/mapping", {"team": team_uuid, "project": u})
    for u in have - set(want_uuids):
        req("DELETE", f"/acl/mapping/team/{team_uuid}/project/{u}")


def import_teams(export, project_uuids):
    existing = {t["name"]: t for t in get("/team?pageSize=500")}
    team_uuids = {}
    for t in export["teams"]:
        name = t["name"]
        perms = perm_names(t.get("permissions"))
        acl_uuids = []
        for a in t.get("aclProjects", []):
            u = project_uuids.get((a["name"], None))
            if not u:
                print(f"  !! ACL target project not found: {a['name']} (team {name})", file=sys.stderr)
            else:
                acl_uuids.append(u)

        if name in existing:
            uuid = existing[name]["uuid"]
            if DRY:
                log(f"team update: {name} perms={len(perms)} acl={len(acl_uuids)}")
            else:
                req("POST", "/team", {"uuid": uuid, "name": name})
                if perms:
                    req("PUT", "/permission/team", {"team": uuid, "permissions": perms})
                reconcile_acl(uuid, acl_uuids)
                stats["updated"] += 1
                log(f"team update: {name}")
        else:
            if DRY:
                log(f"team create: {name} perms={perms} acl={[a['name'] for a in t.get('aclProjects', [])]}")
                stats["created"] += 1
            else:
                st, res = req("PUT", "/team", {"name": name})
                if st >= 400:
                    print(f"  !! team create failed {name}: {st} {res}", file=sys.stderr)
                    continue
                uuid = res["uuid"]
                if perms:
                    req("PUT", "/permission/team", {"team": uuid, "permissions": perms})
                for u in acl_uuids:
                    req("PUT", "/acl/mapping", {"team": uuid, "project": u})
                stats["created"] += 1
                log(f"team create: {name} -> {uuid[:8]}")
        team_uuids[name] = uuid
    return team_uuids


# -------------------------------------------------------------------- tags
def import_tags(export, project_uuids):
    existing = {t["name"]: t for t in get("/tag?pageSize=500")}
    for tg in export["tags"]:
        name = tg["name"]
        want = []
        for p in (tg.get("projects") or []):
            u = project_uuids.get((p["name"], p.get("version")))
            if u:
                want.append(u)
        if name in existing:
            if DRY:
                log(f"tag update: {name} -> {len(want)} projects")
            else:
                for u in want:
                    req("POST", f"/tag/{name}/project", [u])
                stats["updated"] += 1
                log(f"tag update: {name}")
        else:
            if DRY:
                log(f"tag create: {name} -> {len(want)} projects")
                stats["created"] += 1
            else:
                req("PUT", "/tag", [name])
                for u in want:
                    req("POST", f"/tag/{name}/project", [u])
                stats["created"] += 1
                log(f"tag create: {name}")


# ------------------------------------------------------------------- users
def import_users(export, team_uuids, users_file):
    creds = {u["username"]: u.get("password") for u in json.load(open(users_file))}
    existing = {u["username"]: u for u in get("/user/managed?pageSize=500")}
    for u in export["users"]:
        uname = u["username"]
        want_teams = [team_uuids[t["name"]] for t in (u.get("teams") or []) if t["name"] in team_uuids]
        if uname in existing:
            if DRY:
                log(f"user update: {uname} teams={len(want_teams)}")
            else:
                req("PUT", "/user/membership", {"username": uname, "teams": want_teams})
                stats["updated"] += 1
                log(f"user update: {uname}")
        else:
            pw = creds.get(uname)
            if not pw:
                log(f"user skip (no password in --users file): {uname}")
                stats["skipped"] += 1
                continue
            if DRY:
                log(f"user create: {uname} teams={len(want_teams)}")
                stats["created"] += 1
            else:
                st, res = req("PUT", "/user/managed", {
                    "username": uname,
                    "fullname": u.get("fullname") or uname,
                    "email": u.get("email") or f"{uname}@example.com",
                    "newPassword": pw,
                    "confirmPassword": pw,
                    "forcePasswordChange": True,
                    "nonExpiryPassword": False,
                    "suspended": False,
                })
                if st >= 400:
                    print(f"  !! user create failed {uname}: {st} {res}", file=sys.stderr)
                    continue
                req("PUT", "/user/membership", {"username": uname, "teams": want_teams})
                stats["created"] += 1
                log(f"user create: {uname}")


# ------------------------------------------------------- service accounts (v2)
def _v2_available():
    st, _ = req("GET", "/service-accounts?limit=1", base=BASE2)
    return st < 400


def import_service_accounts(export, team_uuids):
    if not _v2_available():
        print("  !! service-account API unavailable (pre-5.2.0 instance?) — skipping", file=sys.stderr)
        return
    existing = {}
    token = None
    while True:
        url = "/service-accounts?limit=500"
        if token:
            url += f"&page_token={token}"
        batch = get(url, base=BASE2)
        items = batch.get("items", batch if isinstance(batch, list) else [])
        for sa in items:
            existing[sa.get("name")] = sa
        token = batch.get("next_page_token") if isinstance(batch, dict) else None
        if not token or not items:
            break

    for sa in export.get("serviceAccounts", []):
        name = sa.get("name")
        if not name:
            continue
        username = sa.get("username") or f"svc:{name}"
        perms = sorted(p if isinstance(p, str) else p.get("name") for p in (sa.get("permissions") or []))
        want_teams = [team_uuids[t["name"]] for t in (sa.get("teams") or []) if t.get("name") in team_uuids]

        if name in existing:
            if DRY:
                log(f"service-account update: {username} perms={len(perms)} teams={len(want_teams)}")
            else:
                # Reconcile direct permissions (v1 user-permission endpoints).
                for p in perms:
                    req("POST", f"/permission/{p}/user/{username}")
                # Reconcile team membership.
                req("PUT", "/user/membership", {"username": username, "teams": want_teams})
                # Re-issue a fresh API key (the old one cannot be read back).
                st, res = req("POST", f"/service-accounts/{name}/api-keys",
                              {"comment": "reissued by import-portfolio"}, base=BASE2)
                if st >= 400:
                    print(f"  !! service-account key reissue failed {username}: {st} {res}", file=sys.stderr)
                else:
                    print(f"  !! NEW API KEY for {username}: {res.get('key')} "
                          f"(public_id={res.get('public_id')}, expires={res.get('expires_at')}) — capture now",
                          file=sys.stderr)
                stats["updated"] += 1
                log(f"service-account update: {username}")
        else:
            if DRY:
                log(f"service-account create: {username} perms={perms} teams={len(want_teams)}")
                stats["created"] += 1
            else:
                st, res = req("POST", "/service-accounts",
                              {"name": name, "email": sa.get("email") or f"{name}@example.com"}, base=BASE2)
                if st >= 400:
                    print(f"  !! service-account create failed {username}: {st} {res}", file=sys.stderr)
                    continue
                for p in perms:
                    req("POST", f"/permission/{p}/user/{username}")
                if want_teams:
                    req("PUT", "/user/membership", {"username": username, "teams": want_teams})
                st, res = req("POST", f"/service-accounts/{name}/api-keys",
                              {"comment": "created by import-portfolio"}, base=BASE2)
                if st >= 400:
                    print(f"  !! service-account key create failed {username}: {st} {res}", file=sys.stderr)
                else:
                    print(f"  !! NEW API KEY for {username}: {res.get('key')} "
                          f"(public_id={res.get('public_id')}, expires={res.get('expires_at')}) — capture now",
                          file=sys.stderr)
                stats["created"] += 1
                log(f"service-account create: {username}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=os.path.join(os.path.dirname(__file__), "portfolio-export.json"))
    ap.add_argument("--users", help="JSON file with [{username, password}] to create missing users")
    ap.add_argument("--service-accounts", action="store_true",
                    help="Create/reconcile service accounts (5.2.0+) and re-issue their API keys")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    global DRY
    DRY = args.dry_run

    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")
    check_auth()
    export = json.load(open(args.export))
    print(f"Target: {BASE}  ({'DRY RUN' if DRY else 'LIVE'})")
    print(f"Source: {export.get('source')}  projects={len(export['projects'])} "
          f"teams={len(export['teams'])} tags={len(export['tags'])} users={len(export['users'])} "
          f"serviceAccounts={len(export.get('serviceAccounts', []))}")

    print("\n== Projects ==")
    project_uuids = import_projects(export)
    print("\n== Teams (permissions + ACLs) ==")
    team_uuids = import_teams(export, project_uuids)
    print("\n== Tags ==")
    import_tags(export, project_uuids)
    if args.users:
        print("\n== Users ==")
        import_users(export, team_uuids, args.users)
    if args.service_accounts:
        print("\n== Service accounts (5.2.0+) ==")
        import_service_accounts(export, team_uuids)

    print(f"\nDone. created={stats['created']} updated={stats['updated']} "
          f"unchanged={stats['unchanged']} skipped={stats['skipped']}")


if __name__ == "__main__":
    main()
