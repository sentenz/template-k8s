#!/usr/bin/env python3
"""
Export the Dependency-Track policy-violation audit trail to a JSON snapshot.

Usage:
  export DTRACK_URL=https://dependency-track.localhost
  export DTRACK_TOKEN=<api-token>          # or DTRACK_API_KEY
  python3 export-violation-audit.py [--out violation-audit-export.json]
                                      [--project <name>] [--include-suppressed]

Captures every policy violation in the portfolio (or a single project) with its
analysis state, suppression flag, and full comment trail. This is the data
behind the "Policy Violation Audit" page and each project's "Policy Violations"
tab.

The snapshot is the source of truth for import-violation-audit.py, which can
re-apply the recorded analysis decisions (state, suppression, comments) to the
matching violations on another instance.

Each violation is exported with:
  - uuid, type (LICENSE|SECURITY|OPERATIONAL), text, timestamp
  - project (name, version, uuid), component (group, name, version, uuid)
  - policyCondition (subject, operator, value)
  - analysis: analysisState (APPROVED|REJECTED|NOT_SET), isSuppressed,
    analysisComments (comment, commenter, timestamp)

Note: requires an admin token (VIEW_POLICY_VIOLATION).
"""
import argparse
import os
import sys

import dtrack_common as dt


def get_violations(project_uuid=None, include_suppressed=False):
    if project_uuid:
        path = f"/api/v1/violation/project/{project_uuid}"
    else:
        path = "/api/v1/violation"
    params = ["pageSize=1000"]
    if include_suppressed:
        params.append("suppressed=true")
    return dt.get(path + "?" + "&".join(params)) or []


def get_analysis(component_uuid, violation_uuid):
    return dt.get(f"/api/v1/violation/analysis?component={component_uuid}"
                  f"&policyViolation={violation_uuid}")


def summarize_component(c):
    if not c:
        return {}
    return {
        "uuid": c.get("uuid"),
        "group": c.get("group"),
        "name": c.get("name"),
        "version": c.get("version"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=dt.default_out("violation-audit-export.json"))
    ap.add_argument("--project", default=None,
                    help="Limit to a single project (matched by name).")
    ap.add_argument("--include-suppressed", action="store_true",
                    help="Include suppressed violations.")
    args = ap.parse_args()
    dt.require_token()
    dt.check_auth()

    project_uuid = None
    project_name = None
    if args.project:
        proj = dt.find_project(args.project)
        if proj is None:
            sys.exit(f"error: project not found: {args.project}")
        project_uuid = proj["uuid"]
        project_name = proj["name"]

    raw = get_violations(project_uuid, args.include_suppressed)
    violations = []
    for v in raw:
        comp = v.get("component") or {}
        analysis = v.get("analysis") or {}
        # Fetch the full comment trail for each violation.
        comments = []
        if comp.get("uuid") and v.get("uuid"):
            try:
                trail = get_analysis(comp["uuid"], v["uuid"])
                # The endpoint returns a list of analysis records (possibly
                # empty/None when no analysis has been recorded yet).
                if isinstance(trail, list) and trail:
                    comments = trail[0].get("analysisComments") or []
                elif isinstance(trail, dict):
                    comments = trail.get("analysisComments") or []
            except RuntimeError:
                comments = analysis.get("analysisComments") or []
        violations.append({
            "uuid": v.get("uuid"),
            "type": v.get("type"),
            "text": v.get("text"),
            "timestamp": v.get("timestamp"),
            "project": {
                "uuid": (v.get("project") or {}).get("uuid"),
                "name": (v.get("project") or {}).get("name"),
                "version": (v.get("project") or {}).get("version"),
            },
            "component": summarize_component(comp),
            "policyCondition": {
                "subject": (v.get("policyCondition") or {}).get("subject"),
                "operator": (v.get("policyCondition") or {}).get("operator"),
                "value": (v.get("policyCondition") or {}).get("value"),
            },
            "analysis": {
                "analysisState": analysis.get("analysisState", "NOT_SET"),
                "isSuppressed": analysis.get("isSuppressed", False),
                "analysisComments": comments,
            },
        })

    out = {
        "exportedAt": os.environ.get("DTRACK_EXPORTED_AT", ""),
        "source": dt.BASE,
        "project": project_name,
        "violations": violations,
    }
    dt.write_json(args.out, out)
    scope = f"project={project_name}" if project_name else "portfolio"
    print(f"Exported {len(violations)} policy violations ({scope}) -> {args.out}")
    for v in violations:
        a = v["analysis"]
        print(f"  - [{v['type']}] {v['project']['name']} "
              f"{v['component'].get('name')}  state={a['analysisState']} "
              f"suppressed={a['isSuppressed']} comments={len(a['analysisComments'])}")


if __name__ == "__main__":
    main()
