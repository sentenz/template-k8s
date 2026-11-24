#!/usr/bin/env python3
"""
Idempotently apply Dependency-Track policies (defined in policies-export.json)
to a target instance.

Usage:
  export DTRACK_URL=https://dependency-track.stage.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-policies.py --dry-run     # preview, no changes
  python3 import-policies.py               # apply

Each policy in the JSON is reconciled against the target:
  - created if missing (PUT /api/v1/policy), updated if present (POST /api/v1/policy)
  - conditions reconciled (missing added, extras removed)
  - project and tag assignments reconciled (matched by name)

Notes:
  - "violationState" is the alarm level: INFO | WARN | FAIL.
  - A VULNERABILITY_ID condition with operator IS matches a component that has
    a finding for that exact vulnerability id (e.g. a CVE).
  - "operator" is the condition combinator: ANY (fire if any condition matches)
    or ALL (fire only if every condition matches).
  - Requires an admin token (POLICY_MANAGEMENT).
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

DRY = False


def auth_headers():
    # API keys (odt_ prefix) authenticate via X-Api-Key; session tokens via Bearer.
    if TOKEN.startswith("odt_"):
        return {"X-Api-Key": TOKEN, "Content-Type": "application/json"}
    return {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=auth_headers())
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


def get(path):
    st, body = req("GET", path)
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        raise RuntimeError(f"GET {path} -> {st}: {body}")
    return body


def check_auth():
    st, _ = req("GET", "/api/v1/policy?pageSize=1")
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        sys.exit(f"error: cannot reach {BASE} ({st}). Check DTRACK_URL.")


def log(msg):
    print(f"  [{'DRY' if DRY else 'OK '}] {msg}")


def list_policies():
    return get("/api/v1/policy?pageSize=1000") or []


def find_policy(name):
    for p in list_policies():
        if p.get("name") == name:
            return p
    return None


def find_project(name):
    for p in get("/api/v1/project?pageSize=1000") or []:
        if p.get("name") == name:
            return p
    return None


def _cond_key(c):
    # Identity for a condition. EXPRESSION (CEL) conditions are stored by the
    # API with operator MATCHES regardless of what was sent, so key on
    # (subject, value) for those to keep reconciliation idempotent.
    if c.get("subject") == "EXPRESSION":
        return ("EXPRESSION", c.get("value"))
    return (c.get("subject"), c.get("operator"), c.get("value"))


def reconcile_conditions(policy_uuid, desired):
    current = get(f"/api/v1/policy/{policy_uuid}")
    cur_conds = current.get("policyConditions", []) or []
    cur_keys = {_cond_key(c) for c in cur_conds}
    want_keys = {_cond_key(c) for c in desired}

    for c in cur_conds:
        key = _cond_key(c)
        if key not in want_keys:
            log(f"delete condition {key}")
            if not DRY:
                st, res = req("DELETE", f"/api/v1/policy/condition/{c['uuid']}")
                if st >= 400:
                    sys.exit(f"error: failed to delete condition {key}: {st} {res}")

    for c in desired:
        key = _cond_key(c)
        if key not in cur_keys:
            log(f"add condition {key}")
            if not DRY:
                st, res = req("PUT", f"/api/v1/policy/{policy_uuid}/condition", c)
                if st >= 400:
                    sys.exit(f"error: failed to add condition {key}: {st} {res}")


def reconcile_projects(policy_uuid, desired_names):
    current = get(f"/api/v1/policy/{policy_uuid}")
    cur_projects = current.get("projects", []) or []
    cur_names = {p.get("name") for p in cur_projects}
    want_names = set(desired_names)

    for p in cur_projects:
        if p.get("name") not in want_names:
            log(f"remove project {p.get('name')}")
            if not DRY:
                st, res = req("DELETE", f"/api/v1/policy/{policy_uuid}/project/{p['uuid']}")
                if st >= 400:
                    sys.exit(f"error: failed to remove project {p.get('name')}: {st} {res}")

    for name in sorted(want_names - cur_names):
        proj = find_project(name)
        if proj is None:
            sys.exit(f"error: project not found: {name}")
        log(f"add project {name}")
        if not DRY:
            st, res = req("POST", f"/api/v1/policy/{policy_uuid}/project/{proj['uuid']}")
            if st >= 400:
                sys.exit(f"error: failed to add project {name}: {st} {res}")


def reconcile_tags(policy_uuid, desired_names):
    current = get(f"/api/v1/policy/{policy_uuid}")
    cur_tags = current.get("tags", []) or []
    cur_names = {t.get("name") for t in cur_tags}
    want_names = set(desired_names)

    for name in sorted(cur_names - want_names):
        log(f"untag {name}")
        if not DRY:
            st, res = req("DELETE", f"/api/v1/tag/{name}/policy", [policy_uuid])
            if st >= 400:
                sys.exit(f"error: failed to untag {name}: {st} {res}")

    for name in sorted(want_names - cur_names):
        log(f"tag {name}")
        if not DRY:
            st, res = req("POST", f"/api/v1/tag/{name}/policy", [policy_uuid])
            if st >= 400:
                sys.exit(f"error: failed to tag {name}: {st} {res}")


def apply_policy(spec):
    name = spec["name"]
    operator = spec.get("operator", "ANY")
    violation_state = spec.get("violationState", "WARN")
    include_children = spec.get("includeChildren", False)
    only_latest = spec.get("onlyLatestProjectVersion", False)

    existing = find_policy(name)
    if existing is None:
        log(f"create policy '{name}' (operator={operator}, state={violation_state})")
        policy_uuid = None
        if not DRY:
            st, res = req("PUT", "/api/v1/policy", {
                "name": name,
                "operator": operator,
                "violationState": violation_state,
                "includeChildren": include_children,
                "onlyLatestProjectVersion": only_latest,
            })
            if st >= 400:
                sys.exit(f"error: failed to create policy '{name}': {st} {res}")
            policy_uuid = res.get("uuid")
            # API quirk: PUT (create) silently resets includeChildren /
            # onlyLatestProjectVersion to false. Re-apply the scalar fields via
            # a POST (update) so they actually persist.
            st, res = req("POST", "/api/v1/policy", {
                "uuid": policy_uuid,
                "name": name,
                "operator": operator,
                "violationState": violation_state,
                "includeChildren": include_children,
                "onlyLatestProjectVersion": only_latest,
            })
            if st >= 400:
                sys.exit(f"error: failed to normalize policy '{name}': {st} {res}")
    else:
        policy_uuid = existing["uuid"]
        changed = (
            existing.get("operator") != operator
            or existing.get("violationState") != violation_state
            or existing.get("includeChildren") != include_children
            or existing.get("onlyLatestProjectVersion") != only_latest
        )
        if changed:
            log(f"update policy '{name}' (operator={operator}, state={violation_state})")
            if not DRY:
                st, res = req("POST", "/api/v1/policy", {
                    "uuid": policy_uuid,
                    "name": name,
                    "operator": operator,
                    "violationState": violation_state,
                    "includeChildren": include_children,
                    "onlyLatestProjectVersion": only_latest,
                })
                if st >= 400:
                    sys.exit(f"error: failed to update policy '{name}': {st} {res}")
        else:
            log(f"policy '{name}' unchanged")

    if policy_uuid is not None:
        reconcile_conditions(policy_uuid, spec.get("conditions", []))
        reconcile_projects(policy_uuid, spec.get("projects", []))
        reconcile_tags(policy_uuid, spec.get("tags", []))
    else:
        # New policy in dry-run: no uuid yet, so just show the intended conditions.
        for c in spec.get("conditions", []):
            log(f"  condition: {c['subject']} {c['operator']} {c['value']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=os.path.join(os.path.dirname(__file__), "policies-export.json"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    global DRY
    DRY = args.dry_run

    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")
    check_auth()
    export = json.load(open(args.export))
    policies = export.get("policies", [])

    print(f"Target: {BASE}  ({'DRY RUN' if DRY else 'LIVE'})")
    print(f"Source: {export.get('source')}  policies={len(policies)}")

    for spec in policies:
        print(f"\n== Policy: {spec['name']} ==")
        apply_policy(spec)

    if DRY:
        print("\nDry run complete. No changes made.")


if __name__ == "__main__":
    main()
