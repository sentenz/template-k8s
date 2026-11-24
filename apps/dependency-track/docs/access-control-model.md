# Least-Privilege Access Control Model for SAMSON / SED / Flow / Flow 2000

This model applies the Dependency-Track Project Access Control (PAC) pattern in a least-privilege way.

The design follows a simple rule:

- Role teams define permissions.
- Access teams define the scope.
- Effective access is the union of both.
- Collection projects define organisational boundaries.
- Regular projects contain the versioned SBOM-bearing releases.

- [1. Logical model](#1-logical-model)
- [2. Least-privilege role design](#2-least-privilege-role-design)
  - [2.1. 2.1 SAMSON root roles](#21-21-samson-root-roles)
  - [2.2. 2.2 SED department roles](#22-22-sed-department-roles)
  - [2.3. 2.3 Flow family roles](#23-23-flow-family-roles)
  - [2.4. 2.4 Flow 2000 service roles](#24-24-flow-2000-service-roles)
- [3. Recommended memberships](#3-recommended-memberships)
- [4. Why this is least privilege](#4-why-this-is-least-privilege)
- [5. Important Dependency-Track caveat](#5-important-dependency-track-caveat)
- [6. Policy statement](#6-policy-statement)
- [7. Summary](#7-summary)

## 1. Logical model

```plaintext
Organisation A
│  Name: SAMSON
│  Type: Collection Project
│  Logic: AGGREGATE_DIRECT_CHILDREN
│  ACL:
│    - team: samson-portfolio-admins        -> ADMIN on SAMSON subtree
│    - team: samson-security-auditors        -> READ on SAMSON subtree
│
├── Department / Group
│    Name: SED
│    Type: Collection Project
│    Logic: AGGREGATE_DIRECT_CHILDREN
│    ACL:
│      - team: sed-admins                   -> ADMIN on SED subtree
│      - team: sed-readers                  -> READ on SED subtree
│
│    └── Product / Service Family
│        Name: Flow
│        Type: Collection Project
│        Logic: AGGREGATE_DIRECT_CHILDREN
│        ACL:
│          - team: flow-admins               -> ADMIN on Flow subtree
│          - team: flow-readers              -> READ on Flow subtree
│
│        └── Product / Service
│            Name: Flow 2000
│            Type: Collection Project
│            Logic: AGGREGATE_LATEST_VERSION_CHILDREN
│            ACL:
│              - team: flow2000-maintainers    -> MAINTAIN on Flow 2000 subtree
│              - team: flow2000-readers        -> READ on Flow 2000 subtree
│              - team: flow2000-ci             -> BOM_UPLOAD on Flow 2000 subtree
│
│            ├── Project
│            │   Name: flow-2000
│            │   Version: 1.2.0
│            │   Classifier: APPLICATION
│            │   Active: true
│            │   Latest: false
│            │   ACL: inherited from Flow 2000
│            │
│            └── Project
│                Name: flow-2000
│                Version: 1.3.0
│                Classifier: APPLICATION
│                Active: true
│                Latest: true
│                ACL: inherited from Flow 2000
```

## 2. Least-privilege role design

### 2.1. 2.1 SAMSON root roles

| Team                     | Permissions                                                                                     | Scope          | Purpose                                                                   |
| ------------------------ | ----------------------------------------------------------------------------------------------- | -------------- | ------------------------------------------------------------------------- |
| samson-portfolio-admins  | `VIEW_PORTFOLIO`, `PORTFOLIO_MANAGEMENT_UPDATE`, `PROJECT_CREATION_UPLOAD`, `ACCESS_MANAGEMENT` | SAMSON subtree | Manage the organisation structure, top-level inventory, and access policy |
| samson-security-auditors | `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`, `VIEW_POLICY_VIOLATION`                                 | SAMSON subtree | Read-only security oversight                                              |

### 2.2. 2.2 SED department roles

| Team        | Permissions                                                                      | Scope       | Purpose                                    |
| ----------- | -------------------------------------------------------------------------------- | ----------- | ------------------------------------------ |
| sed-admins  | `VIEW_PORTFOLIO`, `PORTFOLIO_MANAGEMENT_UPDATE`, `VULNERABILITY_ANALYSIS_UPDATE` | SED subtree | Manage all products and services under SED |
| sed-readers | `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`                                           | SED subtree | Read-only visibility for stakeholders      |

### 2.3. 2.3 Flow family roles

| Team         | Permissions                                                                  | Scope        | Purpose                                   |
| ------------ | ---------------------------------------------------------------------------- | ------------ | ----------------------------------------- |
| flow-admins  | `VIEW_PORTFOLIO`, `PORTFOLIO_MANAGEMENT_UPDATE`, `POLICY_VIOLATION_ANALYSIS` | Flow subtree | Manage product families in the Flow group |
| flow-readers | `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`                                       | Flow subtree | Read-only access for related stakeholders |

### 2.4. 2.4 Flow 2000 service roles

| Team                 | Permissions                                                                                        | Scope             | Purpose                                                               |
| -------------------- | -------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------------- |
| flow2000-maintainers | `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`, `POLICY_VIOLATION_ANALYSIS`, `PORTFOLIO_MANAGEMENT_UPDATE` | Flow 2000 subtree | Own service lifecycle, vulnerability handling, and release governance |
| flow2000-readers     | `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`                                                             | Flow 2000 subtree | Read-only access for developers, QA, and reviewers                    |
| flow2000-ci          | `BOM_UPLOAD`, `PROJECT_CREATION_UPLOAD`                                                            | Flow 2000 subtree | Upload SBOMs and release records for Flow 2000 only                   |

## 3. Recommended memberships

```plaintext
Enterprise admin:
  team: samson-portfolio-admins
  access: SAMSON

SED manager:
  team: sed-admins
  access: SED

Flow owner:
  team: flow-admins
  access: Flow

Flow 2000 service owner:
  team: flow2000-maintainers
  access: Flow 2000

Security reviewer:
  team: samson-security-auditors
  access: SAMSON

CI automation:
  team: flow2000-ci
  access: Flow 2000
```

## 4. Why this is least privilege

- SAMSON admins do not automatically manage SED or Flow 2000.
- SED admins do not automatically manage Flow or Flow 2000 without explicit access.
- Flow 2000 owners only get rights in their own service subtree.
- CI users only have upload rights and do not receive portfolio administration rights.
- Security auditors see the relevant scope but cannot modify it.
- Readers are restricted to read-only access and cannot change project state.
- The same ACL is inherited by both `1.2.0` and `1.3.0`, preventing duplication and drift.

## 5. Important Dependency-Track caveat

Dependency-Track combines rights across memberships. A principal assigned to multiple teams receives the union of permissions across the accessible project scopes.

For example:

- a user in `flow2000-maintainers`
- and also in `flow-readers`

will receive the effective rights of both assignments, across their respective scopes.

This means:

- team names should remain purpose-specific
- identities should not be overloaded with unrelated roles
- if a person needs write access to one service and read-only access to another, use carefully isolated identities or separate access arrangements rather than one broad shared role

## 6. Policy statement

> Only central SAMSON administrators may manage the organisation root. SED admins manage only the SED subtree. Flow admins manage only the Flow family. Flow 2000 maintainers manage only the Flow 2000 service. CI uploaders are limited to BOM_UPLOAD on Flow 2000. Auditors are read-only within the authorised scope.

## 7. Summary

This access model keeps the hierarchy aligned with business ownership and limits each user or automation identity to the minimum scope required. Collection projects define the boundary; role teams define capability; access teams define scope; and the resulting rights remain explicit, reviewable, and easy to reason about.
