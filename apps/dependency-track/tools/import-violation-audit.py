#!/usr/bin/env python3
"""
Apply a recorded policy-violation audit trail (violation-audit-export.json) to a
target instance.

Usage:
  export DTRACK_URL=https://dependency-track.stage.example.com
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 import-violation-audit.py --dry-run   # preview, no changes
  python3 import-violation-audit.py             # apply

For each violation in the snapshot, the matching violation on the target is
located by (component uuid, policy violation uuid) and its analysis decision is
re-applied via PUT /api/v1/violation/analysis:
  - analysisState (APPROVED | REJECTED | NOT_SET)
  - isSuppressed
  - comments (each recorded comment is re-added)

Matching is by the violation's own uuid and its component uuid. If a violation
from the source has no counterpart on the target (e.g. the component or policy
no longer exists), it is reported and skipped.

WARNING: this modifies findings on the target (triage state, suppression, and
audit comments). Prefer --dry-run first.

Note: requires an admin token (POLICY_VIOLATION_ANALYSIS).
"""
import argparse
import sys

import dtrack_common as dt


def list_violations():
    return dt.get("/api/v1/violation?pageSize=1000&suppressed=true") or []


def find_violation(violation_uuid, component_uuid):
    for v in list_violations():
        if v.get("uuid") == violation_uuid and \
                (v.get("component") or {}).get("uuid") == component_uuid:
            return v
    return None


def current_analysis(component_uuid, violation_uuid):
    try:
        return dt.get(f"/api/v1/violation/analysis?component={component_uuid}"
                      f"&policyViolation={violation_uuid}")
    except RuntimeError:
        return None


def apply_violation(spec):
    v_uuid = spec["uuid"]
    comp_uuid = (spec.get("component") or {}).get("uuid")
    analysis = spec.get("analysis") or {}
    state = analysis.get("analysisState", "NOT_SET")
    suppressed = analysis.get("isSuppressed", False)
    comments = analysis.get("analysisComments") or []

    if not v_uuid or not comp_uuid:
        dt.log(f"skip violation (missing uuid): {spec.get('text')}")
        return

    match = find_violation(v_uuid, comp_uuid)
    if match is None:
        dt.log(f"skip violation {v_uuid} (no matching violation on target)")
        return

    cur = current_analysis(comp_uuid, v_uuid) or {}
    cur_state = cur.get("analysisState", "NOT_SET")
    cur_suppressed = cur.get("isSuppressed", False)
    cur_comments = [c.get("comment") for c in (cur.get("analysisComments") or [])]

    if cur_state == state and cur_suppressed == suppressed and not comments:
        dt.log(f"violation {v_uuid} unchanged (state={state}, suppressed={suppressed})")
        return

    dt.log(f"apply violation {v_uuid} (state={state}, suppressed={suppressed}, "
           f"comments={len(comments)})")
    if dt.DRY:
        return

    # Set state + suppression.
    st, res = dt.req("PUT", "/api/v1/violation/analysis", {
        "component": comp_uuid,
        "policyViolation": v_uuid,
        "analysisState": state,
        "isSuppressed": suppressed,
    })
    if st >= 400:
        sys.exit(f"error: failed to set analysis for violation {v_uuid}: {st} {res}")

    # Re-add any comments not already present.
    for c in comments:
        text = c.get("comment")
        if not text or text in cur_comments:
            continue
        st, res = dt.req("PUT", "/api/v1/violation/analysis", {
            "component": comp_uuid,
            "policyViolation": v_uuid,
            "analysisState": state,
            "isSuppressed": suppressed,
            "comment": text,
        })
        if st >= 400:
            sys.exit(f"error: failed to add comment for violation {v_uuid}: {st} {res}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=dt.default_out("violation-audit-export.json"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    dt.DRY = args.dry_run

    dt.require_token()
    dt.check_auth()
    export = dt.read_json(args.export)
    violations = export.get("violations", [])

    dt.banner(dt.BASE, "DRY RUN" if dt.DRY else "LIVE",
              f"violations={len(violations)}")
    print(f"Source: {export.get('source')}  project={export.get('project') or 'portfolio'}")

    for spec in violations:
        apply_violation(spec)

    if dt.DRY:
        print("\nDry run complete. No changes made.")


if __name__ == "__main__":
    main()
