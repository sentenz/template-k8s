#!/usr/bin/env python3
"""
Idempotently apply Dependency-Track service accounts (v2 API) defined in
service-accounts-export.json to a target instance.

Usage:
  export DTRACK_URL=https://dependency-track.stage.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-service-accounts.py --dry-run   # preview, no changes
  python3 import-service-accounts.py             # apply
  python3 import-service-accounts.py --rotate    # also re-issue existing keys

For each service account in the JSON:
  - created if missing (POST /api/v2/service-accounts)
  - team membership reconciled (PUT /api/v1/user/membership) — this is the
    source of truth for access, since project ACLs are team-only and the
    account inherits its team's permissions
  - suspension state reconciled (PATCH /api/v2/service-accounts/{name})
  - one API key issued on create; re-issued for existing accounts only with
    --rotate

Direct permissions ARE granted by default (grant-only). This matches the
recommended pattern where a service account holds its capabilities directly and
its team is a pure access team (ACL only). The snapshot's "permissions" field
is the account's *effective* set, and on the deployed 5.2.x build the v2 GET
reports it unreliably (it can include permissions the account does not actually
hold), so it is only ever used to *grant* — never to revoke. Granting a
permission the account already holds is a no-op. Pass --no-permissions to skip
granting (team membership only).

Notes:
  - API keys are not copied. The plain-text key is returned exactly once at
    creation and cannot be retrieved afterwards. It is printed to stderr —
    capture it into the CI secret store immediately.
  - Team names in the snapshot must exist on the target; missing teams are
    skipped with a warning (the account is still created, just without that
    membership).
  - Requires an admin token (ACCESS_MANAGEMENT).
  - Tolerates pre-5.2.0 targets: if the service-account API is absent, the
    import is skipped.
"""
import argparse
import sys

import dtrack_common as dt


def v2_available():
    st, _ = dt.req("GET", "/api/v2/service-accounts?limit=1")
    return st < 400


def list_all():
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


def team_uuids_by_name():
    return {t["name"]: t["uuid"] for t in dt.get("/api/v1/team?pageSize=500") or []}


def issue_key(name, comment):
    st, res = dt.req("POST", f"/api/v2/service-accounts/{name}/api-keys", {"comment": comment})
    if st >= 400:
        print(f"  !! API key issue failed for {name}: {st} {res}", file=sys.stderr)
        return
    print(f"  !! NEW API KEY svc:{name}: {res.get('key')} "
          f"(public_id={res.get('public_id')}, expires={res.get('expires_at')}) — capture now",
          file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=dt.default_out("service-accounts-export.json"))
    ap.add_argument("--rotate", action="store_true",
                    help="re-issue API keys for service accounts that already exist")
    ap.add_argument("--no-permissions", action="store_true",
                    help="skip granting direct permissions (team membership only)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    dt.DRY = args.dry_run
    grant_perms = not args.no_permissions

    dt.require_token()
    dt.check_auth()

    if not v2_available():
        print("service-account API unavailable (pre-5.2.0 target?) — nothing to do", file=sys.stderr)
        return

    export = dt.read_json(args.export)
    accounts = export.get("serviceAccounts", [])
    teams = team_uuids_by_name()
    existing = {sa["name"]: sa for sa in list_all()}

    dt.banner(dt.BASE, "DRY RUN" if dt.DRY else "LIVE",
              f"serviceAccounts={len(accounts)}"
              f"{'  (granting direct permissions)' if grant_perms else '  (team membership only)'}")
    print(f"Source: {export.get('source')}")

    created = updated = unchanged = 0
    for spec in accounts:
        name = spec["name"]
        username = spec.get("username") or f"svc:{name}"
        want_perms = sorted(spec.get("permissions") or [])
        want_team_names = spec.get("teams") or []
        want_team_uuids = []
        for tn in want_team_names:
            if tn in teams:
                want_team_uuids.append(teams[tn])
            else:
                print(f"  !! team not found on target: {tn} (skipped for {username})", file=sys.stderr)
        want_suspended = bool(spec.get("suspended"))

        print(f"\n== Service account: {username} ==")

        if name not in existing:
            dt.log(f"create service-account {username} "
                   f"(teams={want_team_names}"
                   f"{', direct perms=' + str(want_perms) if grant_perms else ''}) + API key")
            if not dt.DRY:
                st, res = dt.req("POST", "/api/v2/service-accounts",
                                 {"name": name, "email": spec.get("email") or f"{name}@example.com"})
                if st >= 400:
                    sys.exit(f"error: failed to create service-account {username}: {st} {res}")
                if want_team_uuids:
                    dt.req("PUT", "/api/v1/user/membership", {"username": username, "teams": want_team_uuids})
                if grant_perms:
                    for p in want_perms:
                        dt.req("POST", f"/api/v1/permission/{p}/user/{username}")
                issue_key(name, "created by import-service-accounts")
            created += 1
            continue

        # Existing account: reconcile.
        detail = dt.get(f"/api/v2/service-accounts/{name}")
        have_teams = {t.get("name") for t in (detail.get("teams") or [])}
        have_suspended = bool(detail.get("suspended"))

        changes = []
        if set(want_team_names) != have_teams:
            changes.append("teams")
        if want_suspended != have_suspended:
            changes.append("suspended")

        # When granting permissions we always (re)grant the snapshot's set, so
        # the account is not "unchanged" in that mode.
        if not changes and not args.rotate and not grant_perms:
            dt.log(f"service-account {username} unchanged")
            unchanged += 1
            continue

        reason = ', '.join(changes)
        if grant_perms:
            reason = (reason + ', ' if reason else '') + 'grant permissions'
        if args.rotate:
            reason = (reason + ', ' if reason else '') + 'rotate key'
        dt.log(f"update service-account {username} ({reason})")
        if not dt.DRY:
            if "teams" in changes:
                dt.req("PUT", "/api/v1/user/membership", {"username": username, "teams": want_team_uuids})
            if "suspended" in changes:
                dt.req("PATCH", f"/api/v2/service-accounts/{name}", {"suspended": want_suspended})
            if grant_perms:
                # Grant-only: the v2 effective-permissions field is unreliable,
                # so never revoke. Granting an already-held permission is a no-op.
                for p in want_perms:
                    dt.req("POST", f"/api/v1/permission/{p}/user/{username}")
            if args.rotate:
                issue_key(name, "reissued by import-service-accounts")
        updated += 1

    print(f"\nDone. created={created} updated={updated} unchanged={unchanged}")
    if dt.DRY:
        print("Dry run complete. No changes made.")


if __name__ == "__main__":
    main()
