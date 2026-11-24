# Dependency-Track Portfolio Export / Import

Reprovisions the full **Portfolio** (projects + hierarchy, teams, permissions,
ACLs, tags, and optionally managed users) from one Dependency-Track instance to
another (e.g. dev → prod).

## Files

| File                           | Purpose                                                                                                                                   |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `portfolio-export.json`        | Snapshot of the source portfolio (projects, teams, permissions, ACLs, tags, users, service accounts).                                     |
| `export-portfolio.py`          | Exports the source portfolio to `portfolio-export.json`.                                                                                  |
| `import-portfolio.py`          | Idempotent importer that applies the snapshot to a target instance.                                                                       |
| `create-service-accounts.py`   | Creates a service account for each automation (CI) team, grants the team's permissions directly, and issues one API key each.             |
| `service-accounts-export.json` | Snapshot of the source service accounts (name, teams, effective permissions, key metadata).                                               |
| `export-service-accounts.py`   | Exports the service accounts to `service-accounts-export.json`.                                                                           |
| `import-service-accounts.py`   | Idempotently re-provisions the service accounts on a target instance (teams by default; `--permissions` grants direct perms, grant-only). |
| `users.template.json`          | Optional template for supplying user passwords (see below).                                                                               |
| `osv-config-export.json`       | Snapshot of the OSV data source config (ecosystems + settings).                                                                           |
| `export-osv-config.py`         | Exports the OSV data source config to `osv-config-export.json`.                                                                           |
| `import-osv-config.py`         | Idempotently applies the OSV config to a target instance (optionally mirrors).                                                            |
| `policies-export.json`         | Snapshot of the source policies (e.g. CVE alarms) to re-apply on another instance.                                                        |
| `export-policies.py`           | Exports the source policies to `policies-export.json`.                                                                                    |
| `import-policies.py`           | Idempotently reconciles the defined policies (conditions, projects, tags).                                                                |
| `notifications-export.json`    | Snapshot of notification rules (e.g. policy violation email alerts).                                                                      |
| `export-notifications.py`      | Exports the source notification rules to `notifications-export.json`.                                                                     |
| `import-notifications.py`      | Idempotently reconciles the defined notification rules.                                                                                   |
| `dtrack_common.py`             | Shared helpers (auth, HTTP, dry-run, logging) used by all tools.                                                                          |
| `vuln-policies-export.json`    | Snapshot of vulnerability policies (v2, CEL-based).                                                                                       |
| `export-vuln-policies.py`      | Exports the source vulnerability policies (v2) to `vuln-policies-export.json`.                                                            |
| `import-vuln-policies.py`      | Idempotently reconciles the defined vulnerability policies (v2).                                                                          |
| `violation-audit-export.json`  | Snapshot of the policy-violation audit trail (triage state, comments, suppression).                                                       |
| `export-violation-audit.py`    | Exports the policy-violation audit trail to `violation-audit-export.json`.                                                                |
| `import-violation-audit.py`    | Re-applies the recorded violation analysis decisions to a target instance.                                                                |
| `export-project-violations.py` | Read-only report of a single project's policy violations.                                                                                 |

## Makefile tasks

The root `Makefile` wraps these scripts. Set `DTRACK_URL` and `DTRACK_TOKEN`
(admin API token) — either as environment variables or on the `make` command line.

> **Auth header is chosen automatically by credential type:** an API key
> (`odt_` prefix) is sent as `X-Api-Key`, while a session token (JWT) is sent as
> `Authorization: Bearer`. This lets the same task work against instances that
> only accept API keys (e.g. e-dev) as well as browser session tokens.

```bash
# Export the source portfolio to portfolio-export.json
make dtrack-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# Preview the import (no changes)
make dtrack-import-dry-run DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Apply projects, teams, permissions, ACLs, tags
make dtrack-import DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Also create/reconcile managed users (requires users.json)
make dtrack-import-users DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Also create/reconcile service accounts and re-issue their API keys (5.2.0+)
make dtrack-import-service-accounts DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Export the source notification rules to notifications-export.json
make dtrack-notifications-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# Preview applying notification rules (e.g. policy violation email alerts)
make dtrack-notifications-dry-run DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Apply notification rules
make dtrack-notifications-import DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
```

> **Notification rules only.** The built-in publishers (Email, Slack, Webhook,
> …) ship with the instance and cannot be created or modified via the API, so
> these tasks manage **rules** that reference an existing publisher by name
> (e.g. `Email`). SMTP delivery for the email publisher is configured at the
> application level (server config / environment), not through these scripts —
> the rule only carries the recipients (`recipientAddresses`) and subject prefix.

> **Validate with the Console publisher first.** The `Console` publisher writes
> notifications to the API server's stdout and needs no external service. The
> spec ships a `Policy Violations -> Console (validation)` rule alongside the
> email rule so you can confirm a violation is actually emitted and routed
> (watch `kubectl logs` / `docker compose logs --follow apiserver`) before
> relying on email. Remove the Console rule once SMTP is confirmed working.
> Note: the Console publisher rejects any `publisherConfig`, so its rule uses an
> empty `config` (the importer omits `publisherConfig` for empty configs).

## Policy management

Dependency-Track has several distinct policy facets. This toolset covers all of
them with the same conventions (export → JSON snapshot → idempotent import,
`--dry-run` first, Makefile targets):

| Facet                                | UI page                                    | API                                            | Tools                                                     |
| ------------------------------------ | ------------------------------------------ | ---------------------------------------------- | --------------------------------------------------------- |
| Component policies (CVE-alarm style) | Policy Management                          | v1 `/api/v1/policy`                            | `export/import-policies.py`                               |
| Vulnerability policies (CEL)         | Policy Management ▸ Vulnerability Policies | v2 `/api/v2/vuln-policies`                     | `export/import-vuln-policies.py`                          |
| Policy violation audit (triage)      | Policy Violation Audit                     | v1 `/api/v1/violation` + `/violation/analysis` | `export-violation-audit.py` / `import-violation-audit.py` |
| Per-project violations               | Project ▸ Policy Violations tab            | v1 `/api/v1/violation/project/{uuid}`          | `export-project-violations.py`                            |
| Notification rules                   | Administration ▸ Notifications             | v1 `/api/v1/notification/rule`                 | `export/import-notifications.py`                          |

```bash
# Vulnerability policies (v2, CEL-based)
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

Notes:

- **Component vs. vulnerability policies** are different objects. Component
  policies (v1) use structured conditions (e.g. `VULNERABILITY_ID IS CVE-…`);
  vulnerability policies (v2) use a single CEL `condition` plus analysis,
  ratings, priority, and an operation mode (`DISABLED`/`APPLY`/`LOG`).
- **Vulnerability policy import** only re-applies `USER`-managed policies;
  `BUNDLE`-managed ones are exported for reference but skipped (they are
  read-only and managed at the bundle source).
- **Violation audit import modifies findings** (triage state, suppression,
  comments) on the target. Always `--dry-run` first. It matches violations by
  their own uuid + component uuid, so it only affects violations that exist on
  both instances.
- All tools share `dtrack_common.py` for auth, HTTP, dry-run, and logging.

`DTRACK_EXPORT_DIR`, `DTRACK_EXPORT_FILE`, and `DTRACK_USERS_FILE` are overridable
variables if you relocate the files.

### End-to-end policy management (severity tiers, all projects)

A project like **Subversion** is a *collection* node (`version=None`) with one
child project per version (`v1.0.3`, `v1.0.4`, …). Findings — and therefore
policy violations — are recorded on the **version** projects, not the
collection node. The three severity-tiered policies are defined **globally**
(empty `projects`/`tags`) so they apply to *every* project in the instance:

1. **Define policies** in `policies-export.json`. Each policy uses a
   `SEVERITY IS <LEVEL>` condition, a `violationState` (FAIL/WARN/INFO), and
   `includeChildren: true`. Leaving `projects` empty makes the policy global:

   ```json
   {
     "name": "Critical severity findings",
     "operator": "ANY",
     "violationState": "FAIL",
     "includeChildren": true,
     "projects": [],
     "conditions": [{ "subject": "SEVERITY", "operator": "IS", "value": "CRITICAL" }]
   }
   ```

   The current tiers: **Critical → FAIL**, **High → WARN**, **Medium → INFO**,
   **Low → INFO**. To scope a policy to a subtree instead, list the top project
   name(s) in `projects` (keep `includeChildren: true`).

   > **Prefer severity tiers over per-CVE policies.** A `VULNERABILITY_ID IS
   > <CVE>` policy is redundant with the severity tiers (the CVE is already
   > flagged by its severity) and only supports exact `IS`/`IS_NOT` matching —
   > no regex/wildcard. If you need a CVE-specific alarm that must match both
   > `CVE-…` and `DEBIAN-CVE-…` forms, use the **`EXPRESSION` (CEL)** subject
   > instead, e.g. `vulns.exists(vuln, vuln.id.matches(".*CVE-2026-109618"))`
   > (verified working in 5.2.0; the condition also needs a `violationType`).

2. **Apply** them: `make dtrack-policies-import`.
3. **Trigger evaluation** on a version project — policies only produce
   violations when the project is (re)analyzed:

   ```bash
   curl -k -X POST -H "X-Api-Key: $DTRACK_TOKEN" \
     https://dependency-track.localhost/api/v1/finding/project/<versionUuid>/analyze
   ```

4. **Verify** violations: `make dtrack-project-violations DTRACK_PROJECT=Subversion`
   (aggregates across all versions) or `make dtrack-violation-audit-export`.
5. **Notify**: the `POLICY_VIOLATION` notification rules (Console for
   validation, Email to the DevOps DE) fire automatically when violations are
   created.

> **API quirks (v1, verified against 5.2.0):**
> - **`PUT /api/v1/policy` (create) silently resets `includeChildren` and
>   `onlyLatestProjectVersion` to `false`.** `import-policies.py` therefore
>   follows every create with a `POST` (update) to re-apply the scalar fields.
> - **Conditions are stored under `policyConditions`** (not `conditions`) in the
>   policy object, and are managed via `PUT /api/v1/policy/{uuid}/condition`.
> - **`POST /api/v1/policy` (update) does not accept `conditions`/`projects` in
>   the body** — use the dedicated sub-resource endpoints for those.
> - A policy only generates violations for a project it applies to. A policy
>   with **no project assignment is global** (`global=true`) and applies to
>   every project; otherwise it must be assigned directly to the version
>   project, or to the collection with `includeChildren: true`.
> - `POST /api/v1/finding/project/{uuid}/analyze` is what actually runs policy
>   evaluation; creating/updating a policy does not re-evaluate existing
>   findings.

`export-project-violations.py` aggregates across all versions of a project by
default (use `--version v1.0.3` to restrict to one).

## What is imported

- **Projects** — full hierarchy, recreated parent-first. Collections keep their
  `collectionLogic`; version projects keep `classifier`, `isLatest`, `active`.
- **Teams** — recreated with their exact permission set.
- **Permissions** — set per team (reconciled).
- **ACLs** — team → project grants (reconciled: added and removed to match).
- **Tags** — recreated and re-applied to the same version projects.
- **Users** — only with `--users`; existing users' memberships are reconciled,
  missing users are created from the password file.

## Prerequisites on the target

- Portfolio Access Control enabled: `access-management.acl.enabled=true`.
- An **admin** API token (needs `ACCESS_MANAGEMENT`, `PORTFOLIO_MANAGEMENT_*`,
  `TAG_MANAGEMENT`, and user-management rights).

## Usage

```bash
export DTRACK_URL="https://dependency-track.prod.example.com"
export DTRACK_TOKEN="<admin-api-token>"     # or DTRACK_API_KEY

# 1. Preview (no changes)
python3 import-portfolio.py --dry-run

# 2. Apply projects, teams, permissions, ACLs, tags
python3 import-portfolio.py

# 3. (Optional) Also create/reconcile managed users
cp users.template.json users.json
# edit users.json to set real passwords
python3 import-portfolio.py --users users.json
```

## Safety

- **Idempotent** — safe to re-run. Projects match on `(name, version)`, teams on
  name, tags on name. Existing objects are updated, never duplicated.
- **Dry-run first** — `--dry-run` prints every intended action without changing
  anything.
- **Names are instance-wide unique** in Dependency-Track. If the target already
  has a project/team/tag with the same name but a different meaning, resolve the
  conflict before importing.
- **Users** are not created unless `--users` is passed, because passwords are not
  part of the export. New users are created with `forcePasswordChange=true`.

## Regenerating the export

The export was produced from the dev instance. To refresh it, run
`make dtrack-export` (or `python3 export-portfolio.py`) against the source
instance to overwrite `portfolio-export.json`.

## Service accounts (5.2.0+)

Service accounts are the recommended identity for automation (CI pipelines,
scanners, scripts) — a distinct, suspendable, non-human account that
authenticates with its own API keys or via workload identity federation. They
supersede teams that exist only to hold a long-lived API key. See
[docs/user-management.md](../docs/user-management.md) for the model and the
`*-ci` team migration path.

The portfolio tooling provisions them idempotently. There are two ways to move
service accounts between instances:

**Dedicated service-account export/import** (recommended — focused, dry-run
first):

```bash
# Export the service accounts to service-accounts-export.json
make dtrack-service-accounts-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# Preview applying them to the target (no changes)
make dtrack-service-accounts-dry-run DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Apply: create/reconcile accounts + team membership, issue one key per new account
make dtrack-service-accounts-import DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
```

**As part of the full portfolio import** (projects + teams + ACLs + service
accounts in one pass):

```bash
make dtrack-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>
make dtrack-import-service-accounts DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
```

> **Service accounts hold their capabilities directly; their team is a pure
> access team.** This deployment applies the recommended permission/access
> split to service accounts: each `*-ci` team carries **only the ACL** (which
> projects the account can see), and the service account holds its
> **permissions directly** (`BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD`). The
> importer reconciles **team membership** by default (that sets the ACL scope).
> The snapshot's `permissions` field is the account's *effective* set, and the
> deployed 5.2.x build reports it **unreliably** (it can include permissions
> the account does not actually hold), so it must not be used to *revoke*.
> Pass `--permissions` to `import-service-accounts.py` to **grant** the
> snapshot's permissions directly to the account — it is **grant-only** and
> never removes permissions.

**Migrating a CI team to a service account.** `create-service-accounts.py`
creates one service account per automation team (name ending in `-ci` by
default), adds it as a member of that team (ACL scope), **grants the team's
permissions directly to the account**, and issues one API key. Each pipeline
gets a distinct, suspendable identity whose capability is a single, explicit
unit (revoke the permission from the account, or suspend it) rather than a
team-membership change.

**Splitting an existing combined team.** If a `*-ci` team still carries
permissions (the older combined convention), `migrate-ci-permissions.py` moves
them onto the team's service account directly and strips them from the team,
leaving the team as a pure access team. It is idempotent and dry-run first.

```bash
# Preview (no changes)
python3 migrate-ci-permissions.py --dry-run

# Apply
make dtrack-migrate-ci-permissions DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>
```

```bash
# Preview (no changes)
python3 create-service-accounts.py --dry-run

# Create + issue keys (idempotent; existing accounts are skipped)
make dtrack-create-service-accounts DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# Re-issue keys for accounts that already exist
python3 create-service-accounts.py --rotate
```

After creating accounts, re-run `make dtrack-export` so they are recorded in
`portfolio-export.json` and can be reprovisioned on other instances.

Notes:

- **API keys are not re-exported.** The plain-text key is returned by the API
  exactly once at creation and is never stored (only its hash is). The export
  records key *metadata* (`public_id`, `comment`, `created_at`, `expires_at`)
  for reference only.
- **`--service-accounts` re-issues one fresh key per account** and prints the
  plain-text key **once to stderr** — capture it into the CI secret store
  immediately. It cannot be retrieved afterwards.
- **Tolerates pre-5.2.0 instances.** If the `/api/v2/service-accounts` endpoint
  is absent, the export and import skip service accounts and continue with the
  rest of the portfolio.
- Requires `ACCESS_MANAGEMENT` (or the granular `ACCESS_MANAGEMENT_*` variants).

## OSV data source config (ecosystems)

The OSV vulnerability data source is scoped by an **Ecosystems** list. A fresh
instance only mirrors `npm, Go, Maven, NuGet, PyPI` by default, so container
images built from Debian/PHP (Composer) or other ecosystems will match **zero**
vulnerabilities until the relevant ecosystems are added. This tooling copies the
full OSV config (ecosystems + settings) from one instance to another.

```bash
# 1. Export from the source (e.g. Local/Dev)
make dtrack-osv-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# 2. Preview on the target (e.g. Stage/Prod) — no changes
make dtrack-osv-import-dry-run DTRACK_URL=https://dependency-track.stage DTRACK_TOKEN=<token>

# 3. Apply + trigger an OSV mirror
make dtrack-osv-import DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
```

`DTRACK_OSV_FILE` is overridable if you relocate `osv-config-export.json`.

> **Ecosystem names must exactly match the OSV data-dump folder** or the mirror
> fails with a 404 on `<eco>/all.zip`. Verify any name with
> `curl -I https://storage.googleapis.com/osv-vulnerabilities/<eco>/all.zip`
> (200 = ok). Common gotchas: Ruby is `RubyGems` (not `Gem`), Rust is
> `crates.io` (not `Cargo`), PHP is `Packagist` (not `Composer`). The full list
> of defined ecosystems is at
> <https://ossf.github.io/osv-schema/#defined-ecosystems>.
>
> After applying on a target, re-run a project **Reanalyze** so components are
> matched against the newly mirrored data.

## Policies (severity tiers)

`policies-export.json` is the declarative source of truth for Dependency-Track
**component policies**. The current set is four **global severity tiers** that
flag every finding by severity, plus one **CVE-specific** policy, all applied
across all projects:

| Policy                                      | Condition              | State |
| ------------------------------------------- | ---------------------- | ----- |
| Critical severity findings                  | `SEVERITY IS CRITICAL` | FAIL  |
| High severity findings                      | `SEVERITY IS HIGH`     | WARN  |
| Medium severity findings                    | `SEVERITY IS MEDIUM`   | INFO  |
| Low severity findings                       | `SEVERITY IS LOW`      | INFO  |
| Known-bad CVEs (2026-109618/109619, 111497) | `EXPRESSION` (CEL)     | WARN  |

```json
{
  "policies": [
    {
      "name": "Critical severity findings",
      "operator": "ANY",
      "violationState": "FAIL",
      "includeChildren": true,
      "onlyLatestProjectVersion": false,
      "projects": [],
      "tags": [],
      "conditions": [
        { "subject": "SEVERITY", "operator": "IS", "value": "CRITICAL" }
      ]
    }
  ]
}
```

Field semantics:

- **`violationState`** — the alarm level: `INFO`, `WARN`, or `FAIL`.
- **`operator`** — how conditions combine: `ANY` (fire if *any* condition
  matches) or `ALL` (fire only if *every* condition matches).
- **`conditions`** — each is `{subject, operator, value}`. `SEVERITY` + `IS` +
  a level matches components whose findings have that severity.
- **`projects`** / **`tags`** — optional scoping by project name or tag name.
  Leave both empty to apply the policy **instance-wide** (all projects).
- **`includeChildren`** — when scoping to projects, also evaluate their
  descendants.

> **CVE-specific alarms use the `EXPRESSION` (CEL) subject.** A
> `VULNERABILITY_ID IS <CVE>` condition only supports exact `IS`/`IS_NOT`
> matching — no regex/wildcard, and it must match the exact id the data source
> uses (OSV reports Debian packages as `DEBIAN-CVE-…`, not `CVE-…`). A CEL
> condition matches both forms in one expression. The current CVE policy:
>
> ```json
> {
>   "name": "Known-bad CVEs (2026-109618/109619, 2026-111497)",
>   "operator": "ANY",
>   "violationState": "WARN",
>   "includeChildren": true,
>   "projects": [],
>   "tags": [],
>   "conditions": [
>     {
>       "subject": "EXPRESSION",
>       "operator": "IS",
>       "violationType": "SECURITY",
>       "value": "vulns.exists(vuln, vuln.id.matches(\".*(CVE-2026-109618|CVE-2026-109619|CVE-2026-111497)$\"))"
>     }
>   ]
> }
> ```
>
> Notes: `EXPRESSION` conditions **require** a `violationType` (else the API
> 400s). The regex `.*(…|…|…)$` matches both `CVE-…` and `DEBIAN-CVE-…` ids.
> A component policy raises **one violation per matching component** (not per
> CVE). Note these CVEs are also covered by the severity tiers — keep the CVE
> policy only if you want them called out separately or at a different level.

```bash
# 1. Export the source policies (e.g. from Local/Dev)
make dtrack-policies-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# 2. Preview on the target (e.g. Stage/Prod) — no changes
make dtrack-policies-dry-run DTRACK_URL=https://dependency-track.stage DTRACK_TOKEN=<token>

# 3. Apply
make dtrack-policies-import DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
```

`DTRACK_POLICIES_FILE` is overridable if you relocate `policies-export.json`.

> **Idempotent** — safe to re-run. Policies match on name; conditions, project
> assignments, and tags are reconciled (added and removed to match the file).
>
> **Scope note** — with empty `projects`/`tags` the policy is global. To limit
> the alarm to a subtree, list the top project name(s) in `projects` and set
> `includeChildren: true`.
>
> Violations appear after the affected projects are (re)analyzed, so re-run a
> project **Reanalyze** after applying if the CVE findings are not yet present.
