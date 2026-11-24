# Policy Management

How policy facets are defined, evaluated, and managed in this Dependency-Track deployment, and how the tooling provisions them. Dependency-Track has several **distinct** policy objects that are easy to conflate; this document separates them and documents the current policy set.

The recommendations below distinguish **documented** Dependency-Track behaviour from **recommended** conventions for this deployment.

- [1. Policy facets at a glance](#1-policy-facets-at-a-glance)
- [2. Component policies (v1)](#2-component-policies-v1)
  - [2.1. Conditions and subjects](#21-conditions-and-subjects)
  - [2.2. Scope: global vs. subtree](#22-scope-global-vs-subtree)
  - [2.3. Evaluation](#23-evaluation)
- [3. Vulnerability policies (v2, CEL)](#3-vulnerability-policies-v2-cel)
- [4. Policy violation audit (triage)](#4-policy-violation-audit-triage)
- [5. The current policy set](#5-the-current-policy-set)
- [6. Provisioning with the tooling](#6-provisioning-with-the-tooling)
- [7. API quirks (verified against 5.2.x)](#7-api-quirks-verified-against-52x)
- [8. References](#8-references)

## 1. Policy facets at a glance

| Facet                      | UI page                                    | API                                            | Purpose                                                                      | Tools                                                     |
| -------------------------- | ------------------------------------------ | ---------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------- |
| **Component policies**     | Policy Management                          | v1 `/api/v1/policy`                            | Raise **violations** from structured conditions or CEL expressions           | `export/import-policies.py`                               |
| **Vulnerability policies** | Policy Management ▸ Vulnerability Policies | v2 `/api/v2/vuln-policies`                     | Apply **triage decisions** (analysis state, suppression, rating) to findings | `export/import-vuln-policies.py`                          |
| **Policy violation audit** | Policy Violation Audit                     | v1 `/api/v1/violation` + `/violation/analysis` | Record per-violation triage (approve/reject, suppress, comments)             | `export-violation-audit.py` / `import-violation-audit.py` |
| **Per-project violations** | Project ▸ Policy Violations tab            | v1 `/api/v1/violation/project/{uuid}`          | Read-only report of one project's violations                                 | `export-project-violations.py`                            |
| **Notification rules**     | Administration ▸ Notifications             | v1 `/api/v1/notification/rule`                 | Route violations/findings to publishers (Email, Console, …)                  | `export/import-notifications.py`                          |

> [!IMPORTANT]
> **Component policies raise violations; vulnerability policies do not.** Component policies (v1) are the alarming mechanism. Vulnerability policies (v2) are for triage — they override analysis state, suppression, and ratings on findings. Leave the v2 set empty unless you are encoding portfolio-wide triage decisions.

## 2. Component policies (v1)

A component policy is a named set of **conditions** combined by an `operator` (`ANY` / `ALL`). When a project is analyzed and a condition matches, a **policy violation** is produced with the policy's `violationState` (`FAIL`, `WARN`, or `INFO`).

### 2.1. Conditions and subjects

Each condition has a `subject`, an `operator`, a `value`, and (for `EXPRESSION`) a `violationType`.

| Subject            | Example operator / value            | Notes                                                                                 |
| ------------------ | ----------------------------------- | ------------------------------------------------------------------------------------- |
| `SEVERITY`         | `IS CRITICAL`                       | Values `CRITICAL`/`HIGH`/`MEDIUM`/`LOW`/`UNASSIGNED`                                  |
| `VULNERABILITY_ID` | `IS CVE-…`                          | Exact match only; `MATCHES` is non-functional (see §7)                                |
| `EPSS`             | `NUMERIC_GREATER_THAN_OR_EQUAL 0.5` | Exploitation probability                                                              |
| `CWE`              | `CONTAINS_ANY CWE-78, CWE-89`       | Weakness classes                                                                      |
| `LICENSE`          | `IS unresolved`                     | License state                                                                         |
| `AGE`              | `NUMERIC_GREATER_THAN_OR_EQUAL P2Y` | Component age (ISO-8601 duration)                                                     |
| `EXPRESSION`       | `MATCHES <CEL>`                     | CEL expression; **must** include `violationType` (`SECURITY`/`LICENSE`/`OPERATIONAL`) |

> [!NOTE]
> `EXPRESSION` (CEL) is the general-purpose subject for pattern matching, tag checks, version distance, license expressions, and artifact-hash checks. The stored operator is `MATCHES` regardless of the CEL content.

### 2.2. Scope: global vs. subtree

- A policy with **no** `projects` and **no** `tags` assignment is **global** (`global=true`) and applies to every project.
- To scope a policy to a subtree, list the top project name(s) in `projects` and set `includeChildren: true`.
- `onlyLatestProjectVersion: true` restricts evaluation to the latest version of each project.

> [!NOTE]
> Findings — and therefore violations — are recorded on **version** projects, not on the collection node. A project like `Subversion` is a collection node (`version=None`) with one child per version; per-project reports must aggregate across all versions.

### 2.3. Evaluation

Creating or updating a policy does **not** re-evaluate existing findings. You must trigger analysis on a version project:

```bash
curl -k -X POST -H "X-Api-Key: $DTRACK_TOKEN" \
  https://dependency-track.localhost/api/v1/finding/project/<versionUuid>/analyze
```

Violations then appear (asynchronously, ~10 s) via `GET /api/v1/violation/project/{versionUuid}`.

## 3. Vulnerability policies (v2, CEL)

Vulnerability policies are a separate, CEL-based object (`/api/v2/vuln-policies`) surfaced under **Policy Management ▸ Vulnerability Policies**. Each policy has:

- a single CEL `condition`,
- an `analysis` block (`state`, `justification`, `vendor_response`, `details`, `suppress`),
- up to three `ratings` (`method`: `CVSSV2`/`CVSSV3`/`CVSSV4`/`OWASP`),
- an `operation_mode` (`DISABLED` / `APPLY` / `LOG`),
- a `priority` (0–100), and `valid_from` / `valid_until`.

`analysis.state` is one of `EXPLOITABLE` / `IN_TRIAGE` / `FALSE_POSITIVE` / `NOT_AFFECTED` / `RESOLVED`.

> [!IMPORTANT]
> Policies have a `source` of `USER` or `BUNDLE`. **`BUNDLE`-managed policies are read-only** — they cannot be modified or deleted and are managed at the bundle source. The importer only re-applies `USER`-managed policies; `BUNDLE` ones are exported for reference and skipped.

The v2 API uses standard REST verbs (`POST` create, `PUT` update) — the **opposite** of the v1 component-policy API.

## 4. Policy violation audit (triage)

Each policy violation can carry an analysis decision: `analysisState` (`APPROVED` / `REJECTED` / `NOT_SET`), `isSuppressed`, and a list of `analysisComments`.

- **Read** the trail: `GET /api/v1/violation/analysis?component={compUuid}&policyViolation={violUuid}`.
- **Record** a decision: `PUT /api/v1/violation/analysis` with `{component, policyViolation, analysisState, isSuppressed?, comment?}`. Requires `POLICY_VIOLATION_ANALYSIS`.

> [!WARNING]
> `import-violation-audit.py` **modifies findings** (triage state, suppression, comments) on the target. Always `--dry-run` first. It matches violations by their own uuid + component uuid, so it only affects violations that exist on both instances.

## 5. The current policy set

The current `policies-export.json` defines **ten global component policies** (all `operator: ANY`, `includeChildren: true`, empty `projects`/`tags`):

| Policy                                              | State  | Subject                  | Rationale                           |
| --------------------------------------------------- | ------ | ------------------------ | ----------------------------------- |
| Blocked CVE identifiers                             | `FAIL` | `EXPRESSION` (CEL)       | Exact blocklist of known-bad CVEs   |
| Known exploited vulnerabilities (KEV)               | `FAIL` | `EXPRESSION` (CEL)       | `vuln.is_kev`                       |
| High exploitation probability (EPSS ≥ 0.5)          | `FAIL` | `EPSS`                   | Active-exploitation signal          |
| Public-facing: high/critical network vulns (CVSSv3) | `FAIL` | `EXPRESSION` (CEL)       | `public-facing` tag + `AV:N` vector |
| Artifact hash mismatch with upstream                | `FAIL` | `EXPRESSION` (CEL)       | Supply-chain integrity              |
| High-impact weakness classes (CWE)                  | `WARN` | `CWE`                    | Injection/deserialization/overflow  |
| Vulnerabilities requiring severity assessment       | `WARN` | `SEVERITY IS UNASSIGNED` | Triage backlog                      |
| Component releases at least two years old           | `WARN` | `AGE`                    | Stale components                    |
| Components at least one major version behind        | `WARN` | `EXPRESSION` (CEL)       | Version distance                    |
| GPL/AGPL license requires legal review              | `WARN` | `EXPRESSION` (CEL)       | Copyleft exposure                   |
| Missing or unresolved component licenses            | `WARN` | `LICENSE IS unresolved`  | License hygiene                     |

The `vuln-policies-export.json` (v2) set is currently **empty** — consistent with the guidance that v2 policies are for triage, not alarming.

## 6. Provisioning with the tooling

All policy tools follow the same convention: **export → JSON snapshot → idempotent import**, `--dry-run` first, Makefile targets. Set `DTRACK_URL` and `DTRACK_TOKEN`.

```bash
# Component policies (v1)
make dtrack-policies-export   DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>
make dtrack-policies-dry-run  DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
make dtrack-policies-import   DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Vulnerability policies (v2, CEL)
make dtrack-vuln-policies-export   DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>
make dtrack-vuln-policies-dry-run  DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
make dtrack-vuln-policies-import   DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Policy violation audit (triage state, suppression, comments)
make dtrack-violation-audit-export   DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>
make dtrack-violation-audit-dry-run  DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
make dtrack-violation-audit-import   DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Per-project violations report (read-only)
make dtrack-project-violations DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token> DTRACK_PROJECT=Subversion
```

End-to-end flow for component policies:

1. **Define** policies in `policies-export.json` (conditions + `violationState`).
2. **Apply** them: `make dtrack-policies-import`.
3. **Trigger evaluation** on a version project (`POST /api/v1/finding/project/{uuid}/analyze`).
4. **Verify** violations: `make dtrack-project-violations DTRACK_PROJECT=<name>` (aggregates across versions) or `make dtrack-violation-audit-export`.
5. **Notify**: `POLICY_VIOLATION` notification rules (Console for validation, Email to the team) fire automatically when violations are created.

> [!NOTE]
> `import-policies.py` does **not** delete policies absent from the spec. To rename or re-scope a policy, delete the old one first, then re-import.

## 7. API quirks (verified against 5.2.x)

These are non-obvious behaviours confirmed against the deployed 5.2.x build. The tooling already compensates for them.

- **v1 verbs are inverted.** Create = `PUT /api/v1/policy`; update = `POST /api/v1/policy` (with `uuid` in the body).
- **`PUT` (create) silently resets `includeChildren` and `onlyLatestProjectVersion` to `false`** even if you send `true`. `import-policies.py` follows every create with a `POST` (update) to re-apply those scalar fields.
- **Conditions are stored under `policyConditions`** (not `conditions`) in the policy object, and are managed via `PUT /api/v1/policy/{uuid}/condition` (body `{subject, operator, value[, violationType]}`). `POST` to that path is 405. Delete = `DELETE /api/v1/policy/condition/{condUuid}`.
- **`POST /api/v1/policy` (update) ignores `conditions`/`projects`/`tags` in the body.** Use the dedicated sub-resource endpoints: `POST/DELETE /api/v1/policy/{uuid}/project/{projUuid}` and `POST/DELETE /api/v1/tag/{name}/policy` (body = `[policyUuid]`).
- **`EXPRESSION` (CEL) conditions require a `violationType`** (`SECURITY`/`LICENSE`/`OPERATIONAL`) or the request 400s with "Expression conditions must define a violation type".
- **`MATCHES` (regex) is non-functional for non-CEL subjects in 5.2.0** — it accepts and persists a regex value but generates zero violations at evaluation. Use exact `IS` conditions, or route pattern matching through the `EXPRESSION` (CEL) subject.
- **OSV reports Debian packages under `DEBIAN-CVE-…` ids**, not the canonical `CVE-…` id. A `VULNERABILITY_ID IS <id>` policy must match the exact id the data source uses; to be robust, include both `CVE-…` and `DEBIAN-CVE-…` conditions.
- **The findings API caps `pageSize` at 100.** `GET /api/v1/finding/project/{uuid}?pageSize=1000` silently returns only the first 100; paginate with `&page=N`.

## 8. References

- [About component policies](https://dependencytrack.github.io/docs/next/concepts/component-policies/)
- [About vulnerability policies](https://dependencytrack.github.io/docs/next/concepts/vulnerability-policies/)
- [Component policies reference](https://dependencytrack.github.io/docs/next/reference/policies/component-policies/)
- [Vulnerability policies reference](https://dependencytrack.github.io/docs/next/reference/policies/vulnerability-policies/)
- [Condition expressions reference](https://dependencytrack.github.io/docs/next/reference/policies/condition-expressions/)
- [CEL expressions reference](https://dependencytrack.github.io/docs/next/reference/cel-expressions/)
- [About notifications](https://dependencytrack.github.io/docs/next/concepts/notifications/)
- [tools/README.md](../tools/README.md) — export/import tooling and Makefile targets.
- [user-management.md](user-management.md) — the permissions that gate policy management and violation analysis.
