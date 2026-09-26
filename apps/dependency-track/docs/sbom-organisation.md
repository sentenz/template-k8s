# Dependency-Track SBOM Organisation Model

Dependency-Track models a **project** as the primary unit of tracking for components, findings, policy violations, metrics, and access control. For a logical model of **Product → Service / Component → Release / Environment**, the most maintainable enterprise mapping is to use project hierarchy for stable containment, regular projects for SBOM-bearing releases, tags for cross-cutting classifications, and Portfolio Access Control (PAC) for authorization boundaries.

The recommendations below distinguish documented Dependency-Track behaviour from architectural conventions inferred from that behaviour.

- [1. Reference Model](#1-reference-model)
  - [1.1. Hierarchy](#11-hierarchy)
  - [1.2. Release and Environment](#12-release-and-environment)
- [2. Collections, Tags, and Properties](#2-collections-tags-and-properties)
- [3. Release and Environment Alternatives](#3-release-and-environment-alternatives)
- [4. Access Control](#4-access-control)
- [5. Naming and Metadata Conventions](#5-naming-and-metadata-conventions)
- [6. Example](#6-example)
- [7. Trade-offs](#7-trade-offs)
- [8. References](#8-references)

## 1. Reference Model

### 1.1. Hierarchy

**Recommended mapping:**

```plaintext
Product                         Collection Project
└── Service / Component         Collection Project
    ├── Release 1.2.0           Regular Project + SBOM
    └── Release 1.3.0           Regular Project + SBOM
```

- Product
  > **Recommended.** Represent a product as a collection project when it is a logical grouping rather than an independently SBOM-bearing artifact.

- Service / Component
  > **Recommended.** Represent an independently released service, application, library, firmware unit, or similar software item as a collection project when multiple releases must be tracked beneath it.

- Release
  > **Recommended.** Represent each release requiring historical traceability as a regular SBOM-bearing project. Projects sharing the same name and using different `version` values form the native version lineage.

- Collection Project
  > **Documented.** A collection project is a parent used for metric aggregation. It has no classifier, contains no components or services, has no dependency graph, and does not accept BOM uploads.

- Project Identity
  > **Documented.** Project `name + version` is globally unique across the instance. Hierarchy does not create a namespace.

### 1.2. Release and Environment

Environment should normally remain metadata when the same immutable release artifact is deployed to multiple environments.

- Release-oriented default
  > **Recommended.** Store the SBOM on the release project and represent deployment environments using tags such as `env-dev`, `env-test`, and `env-prod`.

- Environment-specific project
  > **Recommended exception.** Create separate environment projects when the deployed BOM, vulnerability audit state, policy state, lifecycle, or ACL must differ independently by environment.

- Repeated upload to the same project version
  > **Documented.** Dependency-Track reconciles the existing project inventory. This is appropriate for rolling or unreleased states such as `main` or `dev`, but it does not preserve immutable release inventories as separate projects.

- Latest version
  > **Documented.** Version strings are opaque and are not semantically sorted. The `latest version` marker is maintained explicitly and can drive collection aggregation.

## 2. Collections, Tags, and Properties

Hierarchy and tags overlap as organisational mechanisms but have different semantics.

| Concern | Preferred mechanism | Rationale |
|---|---|---|
| Product contains services | Project hierarchy | Stable one-parent structural relationship |
| Service contains releases | Project hierarchy | Native version and lifecycle model |
| ACL inheritance | Project hierarchy | Parent access propagates to descendants |
| Product/service risk aggregation | Collection project | Native metric aggregation |
| Environment | Tag by default | Cross-cutting classification |
| Compliance scope | Tag | Supports policy and alert scoping |
| Exposure or criticality | Tag | Many-to-many classification |
| CMDB ID, repository, owner ID | Project property | Typed key-value metadata |

- Tags
  > **Documented.** Tags are global name-only labels with many-to-many attachment. They support project filtering, policy assignment, alert scoping, and tag-filtered collection aggregation. Tags have no per-tag access control.

- Project Properties
  > **Documented.** Properties are typed key-value metadata scoped to one project. Built-in policy, alert, and collection logic does not use them for scoping.

- Tags as hierarchy
  > **Not recommended.** A tag-only hierarchy provides no parent-child navigation, ACL inheritance, structural aggregation, or enforced containment. Tags should describe orthogonal dimensions rather than replace the canonical project tree.

## 3. Release and Environment Alternatives

| Model | History | Environment fidelity | Project count | Operational characteristics |
|---|---|---|---:|---|
| Release projects under service | Strong | Metadata-level | `S × R` | Recommended default |
| Rolling project per environment | Weak release history | Strong current-state view | `S × E` | Low cardinality; requires external historical SBOM archive |
| Release × environment projects | Strong | Strong | `S × R × E` | Maximum fidelity; highest maintenance cost |
| Single rolling service project | Weak | Weak | `S` | Simplest; unsuitable for release traceability |

- One project per release
  > **Recommended default.** Use a stable project name and place the release identifier in `version`, for example `name=product-a.service-1`, `version=1.3.0`.

- One rolling project per environment
  > **Viable alternative.** Appropriate when the primary question is what currently runs in each environment and immutable historical SBOMs are retained elsewhere.

- Service × release × environment
  > **Specialised alternative.** Appropriate when each deployment context requires independent inventory, audit decisions, policy results, metrics, or authorization. Environment must participate in project identity because hierarchy does not namespace `name + version`.

- SBOM history
  > **Limitation.** Dependency-Track time-series metrics describe security posture over time; they are not a replacement for immutable historical SBOM-bearing project versions.

## 4. Access Control

Dependency-Track separates global capabilities from project visibility.

```plaintext
Effective operation = Permission AND ACL access
```

- Permissions
  > **Documented.** Permissions define allowed operations such as `VIEW_PORTFOLIO`, `BOM_UPLOAD`, `PORTFOLIO_MANAGEMENT_UPDATE`, or `VULNERABILITY_ANALYSIS`.

- Portfolio Access Control
  > **Documented.** With PAC enabled, project ACL membership is additionally required for project operations.

- Hierarchical inheritance
  > **Documented.** A team granted access to a parent project can access its descendants. Descendants cannot revoke access inherited from an ancestor.

- Product boundary
  > **Recommended.** Assign a product access team at the product collection when the same group may access all services beneath it.

- Service boundary
  > **Recommended.** Assign service-specific access teams at service collections when service teams must not see one another. Release projects then inherit access automatically.

- Role/access separation
  > **Recommended and documented as a pattern.** Maintain permission teams for capabilities and access teams for project scope. A principal belongs to one or more of each.

Example:

```plaintext
role-sbom-developer
  permissions: VIEW_PORTFOLIO, BOM_UPLOAD, VIEW_VULNERABILITY

access-product-a-service-1
  ACL: Product A / Service 1

user/service-account membership:
  role-sbom-developer + access-product-a-service-1
```

Tags and project properties may describe ownership but do not constitute authorization boundaries.

## 5. Naming and Metadata Conventions

| Field | Convention | Example |
|---|---|---|
| Product collection | Human-readable stable name | `Product A` |
| Service collection | Product-qualified human-readable name | `Product A / Service 1` |
| SBOM project name | Globally unambiguous stable identifier | `product-a.service-1` |
| Project version | Artifact/release identifier | `1.3.0` |
| Environment-specific name | Add environment only when separate project state is required | `product-a.service-1@prod` |
| Classifier | CycloneDX-aligned type | `APPLICATION`, `LIBRARY`, `CONTAINER` |
| Environment tag | Controlled global vocabulary | `env-prod` |
| Compliance tag | Controlled global vocabulary | `pci` |
| Criticality tag | Controlled global vocabulary | `criticality-tier-1` |
| Ownership property | Structured metadata | `ownership.team=service-1-team` |
| Repository property | Structured metadata | `source.repository=git.example.org/product-a/service-1` |

`version` should describe the software artifact rather than its deployment environment unless the environment is intentionally part of project identity.

## 6. Example

Logical model:

```plaintext
Product A
└── Service 1
    ├── release 1.2.0 → prod
    └── release 1.3.0 → dev, test
```

Dependency-Track representation:

```plaintext
Product A
  Type: Collection Project
  ACL: access-product-a-governance

└── Product A / Service 1
    Type: Collection Project
    Collection logic: AGGREGATE_LATEST_VERSION_CHILDREN
    ACL: access-service-1

    ├── Project
    │   Name: product-a.service-1
    │   Version: 1.2.0
    │   Classifier: APPLICATION
    │   Active: true
    │   Latest: false
    │   SBOM: release 1.2.0
    │   Tags: env-prod, criticality-tier-1
    │   Properties: ownership.team=service-1-team
    │
    └── Project
        Name: product-a.service-1
        Version: 1.3.0
        Classifier: APPLICATION
        Active: true
        Latest: true
        SBOM: release 1.3.0
        Tags: env-dev, env-test, criticality-tier-1
        Properties: ownership.team=service-1-team
```

When `1.3.0` reaches production, move the `env-prod` tag from `1.2.0` to `1.3.0`. When `1.2.0` is no longer deployed or supported, mark it inactive and allow the configured retention policy to govern eventual deletion.

> [!NOTE]
> `Latest` and `Active` express different concepts. A release can cease to be the latest while remaining active because it is still deployed or supported.

## 7. Trade-offs

- Release-centric hierarchy
  > **Preferred architecture.** It aligns with native version semantics, preserves historical SBOMs, supports lifecycle retention, limits project cardinality, and provides natural service-level ACL inheritance. Environment-specific audit state is not isolated unless separate projects are introduced.

- Environment-centric hierarchy
  > **Operational alternative.** It gives stable current-state projects for `dev`, `test`, and `prod`, but repeated reconciliation weakens release-level historical traceability inside Dependency-Track.

- Full release × environment matrix
  > **High-fidelity alternative.** It provides independent SBOMs, findings, policies, metrics, and ACLs for every deployment context but multiplies project count and duplicates operational work.

The recommended enterprise architecture is therefore **one canonical Product → Service → Release tree**, with Product and Service represented by collection projects, Release represented by the SBOM-bearing regular project, environment represented by tags/properties by default, and environment-specific projects introduced only when independent tracked state is required. PAC boundaries should be placed at the narrowest stable ownership node, normally Product or Service.

## 8. References

- Dependency-Track [About projects](https://github.com/DependencyTrack/docs/blob/main/docs/concepts/projects.md) documentation.
- Dependency-Track [Organizing projects into hierarchies](https://github.com/DependencyTrack/docs/blob/main/docs/guides/user/organizing-projects.md) documentation.
- Dependency-Track [Managing project versions](https://github.com/DependencyTrack/docs/blob/main/docs/guides/user/managing-project-versions.md) documentation.
- Dependency-Track [About tags](https://github.com/DependencyTrack/docs/blob/main/docs/concepts/tags.md) documentation.
- Dependency-Track [About access control](https://github.com/DependencyTrack/docs/blob/main/docs/concepts/access-control.md) documentation.
- Dependency-Track [Permissions](https://github.com/DependencyTrack/docs/blob/main/docs/reference/permissions.md) reference.
- Dependency-Track [Projects](https://github.com/DependencyTrack/docs/blob/main/docs/reference/projects.md) reference.
- Dependency-Track [Configuring project retention](https://github.com/DependencyTrack/docs/blob/main/docs/guides/administration/configuring-project-retention.md) documentation.
- Dependency-Track [About time series metrics](https://github.com/DependencyTrack/docs/blob/main/docs/concepts/time-series-metrics.md) documentation.
