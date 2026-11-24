#!/usr/bin/env python3
"""
Export a project's policy violations (the project's "Policy Violations" tab) to
a JSON report.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-project-violations.py --project <name> [--out report.json]
                                         [--include-suppressed]

Read-only. Produces a point-in-time report of every policy violation for a
single project, suitable for attaching to a ticket, posting to a channel, or
diffing over time. Unlike export-violation-audit.py (which is the source of
truth for re-applying triage), this is a lightweight report.

Each violation is reported with:
  - type (LICENSE|SECURITY|OPERATIONAL), text, timestamp
  - component (group, name, version)
  - policyCondition (subject, operator, value)
  - analysisState, isSuppressed

Note: requires an admin token (VIEW_POLICY_VIOLATION).
"""
import argparse
import os
import sys

import dtrack_common as dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, help="Project name to report on.")
    ap.add_argument("--version", default=None,
                    help="Restrict to a single project version (e.g. v1.0.3). "
                         "By default all versions of the project are aggregated.")
    ap.add_argument("--out", default=None,
                    help="Output file (default: <project>-violations.json).")
    ap.add_argument("--include-suppressed", action="store_true")
    args = ap.parse_args()
    dt.require_token()
    dt.check_auth()

    # A project name can map to a collection node (version=None) plus one or
    # more version projects. Policy violations are recorded on the version
    # projects where the findings live, so aggregate across all of them.
    all_projects = dt.get("/api/v1/project?pageSize=1000") or []
    matches = [p for p in all_projects if p.get("name") == args.project]
    if not matches:
        sys.exit(f"error: project not found: {args.project}")
    if args.version:
        matches = [p for p in matches if p.get("version") == args.version]
        if not matches:
            sys.exit(f"error: project version not found: {args.project} {args.version}")

    params = ["pageSize=1000"]
    if args.include_suppressed:
        params.append("suppressed=true")
    query = "&".join(params)

    violations = []
    for proj in matches:
        raw = dt.get(f"/api/v1/violation/project/{proj['uuid']}?{query}") or []
        for v in raw:
            a = v.get("analysis") or {}
            c = v.get("component") or {}
            violations.append({
                "uuid": v.get("uuid"),
                "projectVersion": proj.get("version"),
                "type": v.get("type"),
                "text": v.get("text"),
                "timestamp": v.get("timestamp"),
                "component": {
                    "group": c.get("group"),
                    "name": c.get("name"),
                    "version": c.get("version"),
                },
                "policyCondition": {
                    "subject": (v.get("policyCondition") or {}).get("subject"),
                    "operator": (v.get("policyCondition") or {}).get("operator"),
                    "value": (v.get("policyCondition") or {}).get("value"),
                },
                "analysisState": a.get("analysisState", "NOT_SET"),
                "isSuppressed": a.get("isSuppressed", False),
            })

    out_path = args.out or dt.default_out(f"{args.project}-violations.json")
    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": dt.BASE,
        "project": {
            "name": args.project,
            "versions": [p.get("version") for p in matches],
            "uuids": [p["uuid"] for p in matches],
        },
        "count": len(violations),
        "violations": violations,
    }
    dt.write_json(out_path, out)
    versions = ", ".join(str(p.get("version")) for p in matches)
    print(f"Reported {len(violations)} policy violations for "
          f"'{args.project}' ({versions}) -> {out_path}")
    for v in violations:
        print(f"  - [{v['type']}] {v['component'].get('name')} "
              f"({v.get('projectVersion')}) state={v['analysisState']} "
              f"suppressed={v['isSuppressed']}")


if __name__ == "__main__":
    main()
