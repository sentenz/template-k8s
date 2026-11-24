#!/usr/bin/env python3
"""
Idempotently apply an OSV vulnerability data source configuration (exported by
export-osv-config.py) to a target Dependency-Track instance.

Usage:
  export DTRACK_URL=https://dependency-track.stage.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-osv-config.py --dry-run   # preview, no changes
  python3 import-osv-config.py             # apply
  python3 import-osv-config.py --mirror    # also trigger an OSV mirror after applying

Notes:
  - The OSV source config lives on the v2 extension-point API:
        PUT /api/v2/extension-points/vuln-data-source/extensions/osv/config
  - The full config object (enabled, dataUrl, ecosystems, aliasSyncEnabled,
    incrementalMirroringEnabled) is replaced with the exported values.
  - Ecosystem names must exactly match the OSV data-dump folder names or the
    mirror will fail with a 404 on <eco>/all.zip. See
    https://ossf.github.io/osv-schema/#defined-ecosystems
  - Requires an admin token (ACCESS_MANAGEMENT).
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

CONFIG_PATH = "/api/v2/extension-points/vuln-data-source/extensions/osv/config"
MIRROR_PATH = "/api/v2/vuln-data-sources/osv/mirror-runs"

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
    st, _ = req("GET", CONFIG_PATH)
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        sys.exit(f"error: cannot reach {BASE} ({st}). Check DTRACK_URL.")


def log(msg):
    print(f"  [{'DRY' if DRY else 'OK '}] {msg}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=os.path.join(os.path.dirname(__file__), "osv-config-export.json"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--mirror", action="store_true",
                    help="trigger an OSV mirror after applying the config")
    args = ap.parse_args()
    global DRY
    DRY = args.dry_run

    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")
    check_auth()
    export = json.load(open(args.export))
    want = export["config"]
    ecosystems = want.get("ecosystems", [])

    print(f"Target: {BASE}  ({'DRY RUN' if DRY else 'LIVE'})")
    print(f"Source: {export.get('source')}  ecosystems={len(ecosystems)}")

    current_raw = get(CONFIG_PATH)
    current = current_raw.get("config", current_raw) if isinstance(current_raw, dict) else {}

    print("\n== OSV data source config ==")
    for key in ("enabled", "dataUrl", "aliasSyncEnabled", "incrementalMirroringEnabled"):
        if key in want:
            cur = current.get(key)
            mark = "unchanged" if cur == want[key] else "change"
            log(f"{key}: {cur!r} -> {want[key]!r}  ({mark})")

    cur_eco = set(current.get("ecosystems", []))
    want_eco = set(ecosystems)
    added = sorted(want_eco - cur_eco)
    removed = sorted(cur_eco - want_eco)
    log(f"ecosystems: {len(cur_eco)} -> {len(want_eco)}  "
        f"(+{len(added)} added, -{len(removed)} removed)")
    if added:
        log(f"  added:   {', '.join(added)}")
    if removed:
        log(f"  removed: {', '.join(removed)}")

    if DRY:
        print("\nDry run complete. No changes made.")
        return

    # The v2 extension-point endpoint expects the config wrapped in a "config"
    # envelope (a bare config object is rejected with 400 "JSON Processing
    # Failed"). 200 = applied, 304 = already in that state.
    st, res = req("PUT", CONFIG_PATH, {"config": want})
    if st >= 400:
        sys.exit(f"error: failed to apply OSV config: {st} {res}")
    log("config applied" if st == 200 else "config already in desired state (304)")

    if args.mirror:
        print("\n== OSV mirror ==")
        st, res = req("POST", MIRROR_PATH)
        if st >= 400:
            print(f"  !! mirror trigger failed: {st} {res}", file=sys.stderr)
        else:
            log("mirror triggered (runs asynchronously)")


if __name__ == "__main__":
    main()
