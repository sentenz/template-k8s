#!/usr/bin/env python3
"""
Shared helpers for the Dependency-Track export/import tooling.

Every tool in this directory (export-*.py / import-*.py) uses this module so
they share identical auth handling, HTTP plumbing, dry-run behaviour, and
logging. Add a new facet by writing a thin script on top of these primitives.

Environment:
  DTRACK_URL    Base URL of the instance (e.g. https://dependency-track.localhost)
  DTRACK_TOKEN  Admin API token (odt_... key) or a session bearer token
  DTRACK_API_KEY  Alias for DTRACK_TOKEN

Auth header is chosen automatically by credential type: an API key (odt_ prefix)
is sent as X-Api-Key, while a session token (JWT) is sent as Authorization: Bearer.
"""
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

# Set by each tool's main() after parsing --dry-run.
DRY = False


def require_token():
    if not TOKEN:
        sys.exit("Set DTRACK_TOKEN (or DTRACK_API_KEY) and DTRACK_URL.")


def auth_headers():
    if TOKEN.startswith("odt_"):
        return {"X-Api-Key": TOKEN, "Content-Type": "application/json"}
    return {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def req(method, path, body=None):
    """Perform an HTTP request. Returns (status, parsed_body_or_text)."""
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
    """GET that exits on auth failure and raises on other errors."""
    st, body = req("GET", path)
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        raise RuntimeError(f"GET {path} -> {st}: {body}")
    return body


def check_auth(path="/api/v1/policy?pageSize=1"):
    """Lightweight connectivity + auth check. `path` should be a cheap GET."""
    st, _ = req("GET", path)
    if st in (401, 403):
        sys.exit(f"error: authentication failed ({st}) for {BASE}. "
                 f"Check DTRACK_TOKEN (it may have expired) and DTRACK_URL.")
    if st >= 400:
        sys.exit(f"error: cannot reach {BASE} ({st}). Check DTRACK_URL.")


def log(msg):
    print(f"  [{'DRY' if DRY else 'OK '}] {msg}")


def banner(target, mode, extra=""):
    print(f"Target: {target}  ({mode}){('  ' + extra) if extra else ''}")


def find_project(name):
    for p in get("/api/v1/project?pageSize=1000") or []:
        if p.get("name") == name:
            return p
    return None


def find_tag(name):
    for t in get("/api/v1/tag?pageSize=1000") or []:
        if t.get("name") == name:
            return t
    return None


def names(items, key="name"):
    """Extract a list of names from a list of objects, dropping empties."""
    return [i.get(key) for i in (items or []) if i.get(key)]


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def read_json(path):
    with open(path) as f:
        return json.load(f)


def default_out(filename):
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
