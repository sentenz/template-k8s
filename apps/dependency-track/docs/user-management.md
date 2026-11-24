# User Management

How identities are created, authenticated, and granted access in this Dependency-Track deployment, and how the portfolio tooling provisions them. This document is aligned with the current [About access control](https://dependencytrack.github.io/docs/next/concepts/access-control/) reference and the [Permissions reference](https://dependencytrack.github.io/docs/next/reference/permissions/).

The recommendations below distinguish **documented** Dependency-Track behaviour from **recommended** conventions for this deployment.

- [1. User types](#1-user-types)
- [2. Effective permissions](#2-effective-permissions)
- [3. Managed users](#3-managed-users)
- [4. Service accounts](#4-service-accounts)
  - [4.1. Why service accounts over team API keys](#41-why-service-accounts-over-team-api-keys)
  - [4.2. Naming and lifecycle](#42-naming-and-lifecycle)
  - [4.3. Workload identity federation](#43-workload-identity-federation)
- [5. Teams and the permission/access split](#5-teams-and-the-permissionaccess-split)
- [6. Portfolio Access Control interaction](#6-portfolio-access-control-interaction)
- [7. Provisioning with the tooling](#7-provisioning-with-the-tooling)
- [8. Operational runbook](#8-operational-runbook)
- [9. References](#9-references)

## 1. User types

Dependency-Track supports four user types. All four share the same permission model; the authentication mechanism only determines *how* identity is verified, not *what* an identity can access.

| Type                | Authentication                                | Stored in DTrack     | Managed here               |
| ------------------- | --------------------------------------------- | -------------------- | -------------------------- |
| **Managed User**    | Local username + password                     | Yes                  | Yes — via tooling and UI   |
| **LDAP User**       | External LDAP directory                       | No (mapped on login) | No — directory-managed     |
| **OIDC User**       | OpenID Connect identity provider              | No (mapped on login) | No — IdP-managed           |
| **Service Account** | Own API keys, or workload identity federation | Yes                  | Yes — via tooling (5.2.0+) |

> [!NOTE]
> This deployment currently uses **managed users** for humans and **team API keys** for automation. Service accounts (5.2.0+) are available on the deployed 5.2.x build and are the recommended path for new automation — see [4. Service accounts](#4-service-accounts).

## 2. Effective permissions

A principal's effective permissions are the **union** of:

- the permissions assigned **directly** to the user, and
- the permissions of **every team** the user belongs to.

Permissions are never intersected or downgraded by team membership. A user in two teams holds the combined rights of both.

> [!WARNING]
> Because rights are unioned across memberships, a wider read-only membership can widen the reach of a write permission held elsewhere. Keep audit identities free of any mutation permission through *all* of their teams and direct assignments. See [least-privilege-access-control-model.md](least-privilege-access-control-model.md) §1.

## 3. Managed users

Managed users are local accounts created and managed inside Dependency-Track.

- **Create** via the UI (Administration ▸ Access Management ▸ Managed Users) or the API (`PUT /api/v1/user/managed`).
- **Password policy.** The importer creates managed users with `forcePasswordChange: true` and `nonExpiryPassword: false`, so a first login forces a password change and the password is subject to the instance expiry policy.
- **Membership** is set with `PUT /api/v1/user/membership` (a full replacement of the user's team list).
- **Suspension** stops the account's login and any sessions; it does not delete the account.

> [!NOTE]
> The reserved `svc:` username prefix is rejected for managed users (case-insensitive). A managed user can never take a name that a service account would use.

## 4. Service accounts

A **service account** is the identity of a CI pipeline, scanner, script, or other automated tool. It is a non-human account that:

- **cannot log in** — it authenticates only through its own API keys or workload identity federation;
- holds permissions **directly** or through team membership, and appears in team member lists;
- always has a username starting with the reserved `svc:` prefix (e.g. `svc:ci-pipeline`);
- can be **suspended**, which immediately stops all its API keys and blocks new token exchanges without deleting anything;
- requires the `ACCESS_MANAGEMENT` permission to create or manage.

Managing service accounts requires `ACCESS_MANAGEMENT` (or the granular `ACCESS_MANAGEMENT_CREATE` / `_READ` / `_UPDATE` / `_DELETE` variants).

### 4.1. Why service accounts over team API keys

Team API keys belong to a team and carry that team's permissions, but they do **not** associate a request with a specific identity. Service accounts are the strategic replacement for teams that exist only to hold a long-lived API key:

| Concern                               | Team API key           | Service account                                                    |
| ------------------------------------- | ---------------------- | ------------------------------------------------------------------ |
| Identity per tool                     | Shared (the team)      | Distinct per tool, even within one team                            |
| Narrowing one tool's rights           | Needs a dedicated team | Direct permissions on the account                                  |
| Stopping access without deleting keys | No                     | Yes — suspend the account                                          |
| Credential storage                    | Long-lived static key  | Optional — workload identity federation needs no stored credential |
| Audit trail                           | Team                   | The service account's username                                     |

> [!RECOMMENDATION]
> Start new integrations on service accounts. The existing `*-ci` teams (e.g. `samson-group-mantis-ci`, `samson-sed-flow-2000-ci`) are the old model — one shared key per team. Migrate each to a distinct service account so every pipeline has its own identity, its own (narrow) permission set, and can be suspended independently.

### 4.2. Naming and lifecycle

- **Naming.** Use `svc:<org>-<group>-<product>-<purpose>`, e.g. `svc:samson-mantis-ci`. The name after `svc:` is what the API path uses; the full username is `svc:` + name.
- **Permissions.** Grant the minimum set directly (e.g. `BOM_UPLOAD` for an uploader). Prefer direct permissions for a single tool over creating a one-member team.
- **API keys.** A key's plain text is returned **exactly once** at creation and cannot be read back (only its hash is stored). Capture it into the CI secret store immediately. Keys can be individually deleted.
- **Suspension vs. deletion.** Suspend to stop access while keeping keys and bindings for re-enablement. Deleting a service account also deletes its API keys and its workload identity bindings.

### 4.3. Workload identity federation

Available in 5.2.0 and later. Instead of storing an API key, a workload exchanges a short-lived token issued by its own platform (GitHub Actions, GitLab CI, Kubernetes, SPIFFE) for a session of the service account.

- A **workload identity provider** (instance-wide, admin-managed) declares which issuer to trust, the required audience, where the issuer's signing keys come from, and the session lifetime (max 24 h).
- A **workload identity binding** belongs to a service account, names a provider, and matches a subject (exactly or by prefix), optionally narrowed by a CEL condition on token claims.
- The exchange returns an opaque session token carrying all of the service account's permissions.

> [!NOTE]
> A session outlives the platform token that created it, so deleting a binding or provider does not end already-created sessions — suspending the service account does, at once. Workload identity federation is not yet configured in this deployment; it is the end-state for the `*-ci` automation once service accounts are in place.

## 5. Teams and the permission/access split

A **team** is a named collection of users and API keys that holds permissions. The current access-control reference recommends splitting teams by role:

- **Permission teams** carry capabilities (`VIEW_PORTFOLIO`, `VULNERABILITY_ANALYSIS_UPDATE`, …) but are assigned to **no** project.
- **Access teams** hold **no** permissions but are assigned to a subset of projects (their ACL).

A user joins one team of each kind; effective rights are the union of all teams' permissions, scoped to the union of all teams' ACL grants. This emulates per-project permissions, which the model does not support directly.

> [!IMPORTANT]
> **This deployment uses the split for service accounts and the combined model for human teams.**
>
> - **Service accounts** (the `*-ci` automation): each `*-ci` team is a **pure access team** (ACL only), and the service account holds its capabilities **directly** (`BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD`). This was applied by `tools/migrate-ci-permissions.py` (idempotent). Revoking a service account's capability is then a single explicit action (revoke the permission from the account, or suspend it) rather than a team-membership change, and the team's ACL still scopes *where* it can act.
> - **Human teams** (e.g. `samson-group-mantis-team`): still **combined** — the team holds both the permissions and the ACL, and members inherit both. That is a valid, simpler choice for people.
>
> The [least-privilege-access-control-model.md](least-privilege-access-control-model.md) describes the split; this document records the actual convention. Keep the two styles consistent within their scope (service accounts vs. humans) and document any deviation.

## 6. Portfolio Access Control interaction

Permissions and ACLs are **orthogonal**:

- **Permissions** define *what* a principal can do. They are global to the principal; there are no per-project permissions.
- **ACLs** define *which projects* a principal can do it on. They gate both reads and writes.

To act on a project, a principal needs **both** the relevant permission **and** ACL access to that project.

Key behaviours that affect user management:

- **Inheritance.** ACL grants flow **down** the project hierarchy. Granting a team on a parent grants it on every descendant, current and future.
- **Bypass.** `PORTFOLIO_ACCESS_CONTROL_BYPASS` exempts a principal from PAC entirely. Reserve it for administrators and trusted automation.
- **Project creation under PAC.**
  - When a **team API key or service account** creates a project (e.g. via BOM upload with `PROJECT_CREATION_UPLOAD`), Dependency-Track adds the key's **first team (alphabetical)** to the new project's ACL. A service account in no team adds no team.
  - When a **user** creates a project, they must designate an owning team from their own teams; that team is added to the ACL. A project created with no team is invisible to everyone except administrators and `PORTFOLIO_ACCESS_CONTROL_BYPASS` holders until one is assigned.

> [!WARNING]
> The "first team alphabetically" rule means a service account that belongs to multiple teams will seed a new project's ACL with whichever team sorts first. If a service account should seed a specific team, keep it in exactly one team, or create the project explicitly with the intended owning team.

## 7. Provisioning with the tooling

The portfolio tooling in [`tools/`](../tools/) provisions users, teams, and service accounts idempotently. Set `DTRACK_URL` and `DTRACK_TOKEN` (an admin API key or session token).

```bash
# Export the source portfolio (projects, teams, ACLs, tags, users, service accounts)
make dtrack-export DTRACK_URL=https://dependency-track.localhost DTRACK_TOKEN=<token>

# Preview the import (no changes)
make dtrack-import-dry-run DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Apply projects, teams, permissions, ACLs, tags
make dtrack-import DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Also create/reconcile managed users (requires users.json with passwords)
make dtrack-import-users DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>

# Also create/reconcile service accounts and re-issue their API keys (5.2.0+)
make dtrack-import-service-accounts DTRACK_URL=https://dependency-track.prod DTRACK_TOKEN=<token>
```

Behaviour:

- **Managed users** are created only when `--users` is supplied (passwords are never part of the export). Existing users' team memberships are reconciled to match the export.
- **Service accounts** are created only when `--service-accounts` is supplied. Each account is (re)created with its direct permissions and team memberships, and a **fresh API key is issued**. The plain-text key is printed once to stderr and must be captured — it cannot be retrieved afterwards.
- **API keys are not re-exported.** The export records each service account's key *metadata* (`public_id`, `comment`, `created_at`, `expires_at`) for reference; the secret itself is not stored and cannot be copied between instances.

> [!NOTE]
> The export tolerates pre-5.2.0 instances: if the `/api/v2/service-accounts` endpoint is absent, the export and import skip service accounts and continue with the rest of the portfolio.

## 8. Operational runbook

### 8.1. Create a service account for a new pipeline

1. Create the account (UI or `POST /api/v2/service-accounts` with `{"name": "samson-mantis-ci"}`).
2. Grant the minimum permissions directly (`POST /api/v1/{PERMISSION}/user/svc:samson-mantis-ci`), e.g. `BOM_UPLOAD`.
3. Add it to the relevant access team for ACL scope (`PUT /api/v1/user/membership`).
4. Issue an API key (`POST /api/v2/service-accounts/samson-mantis-ci/api-keys`) and store the returned key in the CI secret store.
5. Record the account in `portfolio-export.json` so it is reprovisioned on other instances.

### 8.2. Stop a compromised pipeline

Suspend the service account (`PATCH /api/v2/service-accounts/<name>` with `{"suspended": true}`). This stops all its API keys and federation sessions immediately, without deleting keys or bindings.

### 8.3. Rotate a service-account key

Delete the old key (`DELETE /api/v2/service-accounts/<name>/api-keys/<public_id>`) and issue a new one. Update the CI secret.

### 8.4. Clean up an orphan user

A managed user with no teams (e.g. a leftover `dev*` account) can log in but has no effective access under PAC. Remove it or assign it to a team.

## 9. References

- [About access control](https://dependencytrack.github.io/docs/next/concepts/access-control/) — users, teams, service accounts, PAC.
- [Permissions reference](https://dependencytrack.github.io/docs/next/reference/permissions/) — full permission table and default teams.
- [About workload identity federation](https://dependencytrack.github.io/docs/next/concepts/workload-identity-federation/) — credential-free service-account authentication.
- [Configuring workload identity federation](https://dependencytrack.github.io/docs/next/guides/administration/configuring-workload-identity-federation/) — per-platform setup.
- [About projects](https://dependencytrack.github.io/docs/next/concepts/projects/) — hierarchy and collection projects.
- [organisation-hierarchy-model.md](organisation-hierarchy-model.md) — how the project hierarchy maps to ownership.
- [least-privilege-access-control-model.md](least-privilege-access-control-model.md) — role templates and the permission/access split.
- [tools/README.md](../tools/README.md) — export/import tooling and Makefile targets.
