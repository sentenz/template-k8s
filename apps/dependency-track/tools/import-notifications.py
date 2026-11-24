#!/usr/bin/env python3
"""
Idempotently apply Dependency-Track notification rules (defined in
notifications-export.json) to a target instance.

Usage:
  export DTRACK_URL=https://dependency-track.stage.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-notifications.py --dry-run   # preview, no changes
  python3 import-notifications.py             # apply

Each rule in the JSON is reconciled against the target:
  - created if missing (PUT /api/v1/notification/rule),
    then updated (POST /api/v1/notification/rule) to set the groups and
    publisher config, which the create endpoint does not accept.
  - project and tag assignments reconciled (matched by name)

Notes:
  - "scope" is SYSTEM (platform events) or PORTFOLIO (project events).
  - "level" is INFORMATIONAL | WARNING | ERROR.
  - "notifyOn" is a list of notification group names, e.g. POLICY_VIOLATION
    (event) or NEW_POLICY_VIOLATIONS_SUMMARY (schedule).
  - "publisher" is matched by NAME against the target's existing publishers
    (e.g. the built-in "Email" publisher). Publishers are not created here:
    the built-in publishers ship with the instance and cannot be modified via
    the API. SMTP delivery is configured at the application level, not through
    this script.
  - "config" is the publisher-specific alert config (for email:
    recipientAddresses + subjectPrefix). It is stored on the rule as a JSON
    string in the "publisherConfig" field.
  - Requires an admin token (SYSTEM_CONFIGURATION).
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
    st, _ = req("GET", "/api/v1/notification/rule")
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        sys.exit(f"error: cannot reach {BASE} ({st}). Check DTRACK_URL.")


def log(msg):
    print(f"  [{'DRY' if DRY else 'OK '}] {msg}")


def list_publishers():
    return get("/api/v1/notification/publisher") or []


def find_publisher(name):
    for p in list_publishers():
        if p.get("name") == name:
            return p
    return None


def list_rules():
    return get("/api/v1/notification/rule") or []


def find_rule(name):
    for r in list_rules():
        if r.get("name") == name:
            return r
    return None


def get_rule_by_uuid(rule_uuid):
    # There is no GET /rule/{uuid} endpoint in this API version; look it up in the list.
    for r in list_rules():
        if r.get("uuid") == rule_uuid:
            return r
    return None


def find_project(name):
    for p in get("/api/v1/project?pageSize=1000") or []:
        if p.get("name") == name:
            return p
    return None


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


def reconcile_projects(rule_uuid, desired_names):
    current = get_rule_by_uuid(rule_uuid)
    if current is None:
        sys.exit(f"error: rule not found by uuid: {rule_uuid}")
    cur_projects = current.get("projects", []) or []
    cur_names = {p.get("name") for p in cur_projects}
    want_names = set(desired_names)

    for p in cur_projects:
        if p.get("name") not in want_names:
            log(f"remove project {p.get('name')}")
            if not DRY:
                st, res = req("DELETE", f"/api/v1/notification/rule/{rule_uuid}/project/{p['uuid']}")
                if st >= 400:
                    sys.exit(f"error: failed to remove project {p.get('name')}: {st} {res}")

    for name in sorted(want_names - cur_names):
        proj = find_project(name)
        if proj is None:
            sys.exit(f"error: project not found: {name}")
        log(f"add project {name}")
        if not DRY:
            st, res = req("POST", f"/api/v1/notification/rule/{rule_uuid}/project/{proj['uuid']}")
            if st >= 400:
                sys.exit(f"error: failed to add project {name}: {st} {res}")


def reconcile_tags(rule_uuid, desired_names):
    current = get_rule_by_uuid(rule_uuid)
    if current is None:
        sys.exit(f"error: rule not found by uuid: {rule_uuid}")
    cur_tags = current.get("tags", []) or []
    cur_names = {t.get("name") for t in cur_tags}
    want_names = set(desired_names)

    for name in sorted(cur_names - want_names):
        log(f"untag {name}")
        if not DRY:
            st, res = req("DELETE", f"/api/v1/tag/{name}/notificationRule", [rule_uuid])
            if st >= 400:
                sys.exit(f"error: failed to untag {name}: {st} {res}")

    for name in sorted(want_names - cur_names):
        log(f"tag {name}")
        if not DRY:
            st, res = req("POST", f"/api/v1/tag/{name}/notificationRule", [rule_uuid])
            if st >= 400:
                sys.exit(f"error: failed to tag {name}: {st} {res}")


def apply_rule(spec):
    name = spec["name"]
    scope = spec.get("scope", "PORTFOLIO")
    level = spec.get("level", "INFORMATIONAL")
    enabled = spec.get("enabled", True)
    notify_on = spec.get("notifyOn", [])
    config = spec.get("config", {})

    # Resolve the publisher reference by name (built-in publishers only).
    pub_name = spec["publisher"]
    pub = find_publisher(pub_name)
    if pub is None:
        available = [p.get("name") for p in list_publishers()]
        sys.exit(f"error: publisher not found: {pub_name!r}. "
                 f"Available publishers: {available}")
    publisher_ref = {"uuid": pub["uuid"]}

    def update_body(rule_uuid):
        # Build the update (POST) body. publisherConfig is only sent when the
        # config is non-empty: some publishers (e.g. Console) reject any
        # publisherConfig with "The publisher does not support configuration."
        body = {
            "uuid": rule_uuid,
            "name": name,
            "scope": scope,
            "level": level,
            "enabled": enabled,
            "publisher": publisher_ref,
            "notifyOn": notify_on,
        }
        if config:
            body["publisherConfig"] = json.dumps(config)
        return body

    existing = find_rule(name)
    if existing is None:
        log(f"create rule '{name}' (scope={scope}, level={level}, "
            f"notifyOn={notify_on}, publisher={pub_name})")
        rule_uuid = None
        if not DRY:
            # Create takes only the basic fields; groups + config are set on update.
            st, res = req("PUT", "/api/v1/notification/rule", {
                "name": name,
                "scope": scope,
                "level": level,
                "publisher": publisher_ref,
            })
            if st >= 400:
                sys.exit(f"error: failed to create rule '{name}': {st} {res}")
            rule_uuid = res.get("uuid")
            # Set notifyOn + publisherConfig via the update endpoint.
            st, res = req("POST", "/api/v1/notification/rule", update_body(rule_uuid))
            if st >= 400:
                sys.exit(f"error: failed to configure rule '{name}': {st} {res}")
    else:
        rule_uuid = existing["uuid"]
        cur_pub = (existing.get("publisher") or {}).get("uuid")
        cur_notify = sorted(existing.get("notifyOn", []) or [])
        cur_config = parse_publisher_config(existing.get("publisherConfig"))
        changed = (
            existing.get("scope") != scope
            or existing.get("notificationLevel") != level
            or existing.get("enabled") != enabled
            or cur_notify != sorted(notify_on)
            or cur_pub != pub["uuid"]
            or cur_config != config
        )
        if changed:
            log(f"update rule '{name}' (notifyOn={notify_on})")
            if not DRY:
                st, res = req("POST", "/api/v1/notification/rule", update_body(rule_uuid))
                if st >= 400:
                    sys.exit(f"error: failed to update rule '{name}': {st} {res}")
        else:
            log(f"rule '{name}' unchanged")

    if rule_uuid is not None:
        reconcile_projects(rule_uuid, spec.get("projects", []))
        reconcile_tags(rule_uuid, spec.get("tags", []))
    else:
        # New rule in dry-run: no uuid yet, so just show the intended assignments.
        for p in spec.get("projects", []):
            log(f"  project: {p}")
        for t in spec.get("tags", []):
            log(f"  tag: {t}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=os.path.join(os.path.dirname(__file__), "notifications-export.json"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    global DRY
    DRY = args.dry_run

    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")
    check_auth()
    export = json.load(open(args.export))
    rules = export.get("rules", [])

    print(f"Target: {BASE}  ({'DRY RUN' if DRY else 'LIVE'})")
    print(f"Source: {export.get('source')}  rules={len(rules)}")

    for spec in rules:
        print(f"\n== Rule: {spec['name']} ==")
        apply_rule(spec)

    if DRY:
        print("\nDry run complete. No changes made.")


if __name__ == "__main__":
    main()
