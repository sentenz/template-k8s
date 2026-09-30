# Dependency-Track SBOM Organisation

A Dependency-Track software bill of materials (SBOM) organisation model defines how released software, ownership, deployment context, and reporting map to projects in [Dependency-Track][projects]. A project is the unit that holds inventory and analysis state; its parent relationship, metadata, and access assignments determine how that state is organised and exposed.

This reference architecture evaluates **Organisation → Group → Product → Service or Independently Released Component**. A component at this organisational level is a separately released library, container image, or other artifact. Dependencies inside its SBOM remain inventory entries rather than becoming separate organisational projects. [Configuration examples](../examples/dependency-track/README.md) express the worked model as native policy files and local declarations for SBOM organisation and portfolio access control.

- [1. Evidence and Version Scope](#1-evidence-and-version-scope)
- [2. Project Model](#2-project-model)
  - [2.1. Identity and Release Families](#21-identity-and-release-families)
  - [2.2. Structural Hierarchy](#22-structural-hierarchy)
  - [2.3. Collection Aggregation](#23-collection-aggregation)
  - [2.4. Tags and Properties](#24-tags-and-properties)
- [3. Releases and Environments](#3-releases-and-environments)
  - [3.1. Retained Release Inventories](#31-retained-release-inventories)
  - [3.2. Promotion and Independent Contexts](#32-promotion-and-independent-contexts)
  - [3.3. Analysis and Reporting](#33-analysis-and-reporting)
- [4. Access Control](#4-access-control)
  - [4.1. Permissions and Project Access](#41-permissions-and-project-access)
  - [4.2. Team Boundaries](#42-team-boundaries)
  - [4.3. Provisioning and Maintenance](#43-provisioning-and-maintenance)
- [5. Naming and Metadata Conventions](#5-naming-and-metadata-conventions)
- [6. Worked Example](#6-worked-example)
  - [6.1. Project Records](#61-project-records)
  - [6.2. Tags and Ownership Properties](#62-tags-and-ownership-properties)
  - [6.3. Team Access](#63-team-access)
  - [6.4. Aggregate Membership](#64-aggregate-membership)
- [7. Architecture Comparison and Recommendation](#7-architecture-comparison-and-recommendation)
  - [7.1. Viable Models](#71-viable-models)
  - [7.2. Recommended Reference Architecture](#72-recommended-reference-architecture)
- [8. References](#8-references)

## 1. Evidence and Version Scope

The primary reference is the current `DependencyTrack/docs` repository, inspected on **2026-09-27** at [revision `d46daa5c13c1abba24b29e6425beb6b1f0fbf12a`][docs-revision], committed on 2026-09-24. Documentation links below are pinned to that revision. This is a v5 documentation baseline, not a claim that every capability on `main` is available in every v5 release.

The article distinguishes three kinds of statements:

- Documented Behaviour
  > Project identity, collection modes, access inheritance, and permissions follow the cited Dependency-Track documentation. Supplementary implementation evidence is identified explicitly where the documentation leaves material detail unclear.

- Architectural Recommendation
  > The chosen inventory boundary, reporting design, team placement, and lifecycle procedures are recommendations derived from those capabilities.

- Local Convention
  > Names, tag prefixes, ownership property keys, and the meaning assigned to the latest flag are organisation-defined conventions. They do not create native object types or authorisation rules.

| Capability | Version qualification | Consequence |
| --- | --- | --- |
| Collections, project versions, and inherited access | Described by the pinned v5 project and access documentation | Use the documented model and validate the installed release's interfaces. |
| Portfolio Access Control (PAC) and per-action permissions | The [v5 changes][v5-changes] describe PAC leaving beta; the [API changes][api-changes] identify the added per-action permissions | Do not assume v4 has the same enforcement or permission granularity. |
| Inactive-project retention | Documented as a v5 addition | Retirement can make retained records eligible for deletion. |
| Scheduled portfolio analysis | The [5.1.0 upgrade guide][upgrade-51] changes fixed daily scheduling to age-based scheduling per project | Reanalysis timing depends on the installed version and configuration. |
| Service accounts | The [5.2.0 upgrade guide][upgrade-52] explicitly marks that version unreleased at this documentation revision | Use supported team API keys for the existing baseline; do not require service accounts. |

This repository's [vendored chart](../vendor/helm/dependency-track-2.0.0/dependency-track/Chart.yaml) declares chart version `2.0.0` and application version `5.0.4`. That declaration is not evidence of a running instance's version. The architecture does not depend on the unreleased service-account feature and does not change the deployment configuration.

## 2. Project Model

The logical hierarchy describes ownership and composition. Dependency-Track supplies a single-parent project hierarchy, ordinary projects with inventories, and collection projects with aggregated metrics. It does not require a project at every organisational level.

### 2.1. Identity and Release Families

**Documented behaviour:** A project's name and optional version form an instance-wide unique pair, independent of its parent. Versions are opaque strings; Dependency-Track does not infer release ordering from them. Projects with the same name form a release family, and at most one project per name has the latest-version flag. The flag is maintained explicitly. The [project reference][project-reference] and [version guide][versions] define these constraints; the [API schema][openapi] exposes the record's universally unique identifier (UUID).

**Recommendation:** Keep a stable name for a released artifact and create a distinct project record for each release that must remain inspectable. Persist the returned UUID for uploads and integration mappings. Moving a project to another parent does not establish a new naming namespace. A regrouping or ownership change should normally update the parent and metadata without renaming the release family.

Use a distinct name for the service's grouping collection, such as `org-a.product-a.service-1.releases`, and the SBOM-bearing release family, such as `org-a.product-a.service-1`. The collection is a stable container for records; it is not another release of the service.

### 2.2. Structural Hierarchy

The following mapping is a recommendation. Organisation, group, and product are business concepts represented through ordinary Dependency-Track project fields; they are not native tenant types.

| Logical element | Recommended representation | Inventory placement |
| --- | --- | --- |
| Organisation | Optional collection for organisation-wide governance | No SBOM |
| Group | Optional collection for a meaningful reporting or access boundary | No SBOM |
| Product | Collection grouping independently released services or artifacts | No SBOM |
| Service or independently released component | Stable collection grouping its release records | No SBOM |
| Retained release | Ordinary project with the artifact's name and release version | Its own SBOM |
| Deployment environment | Metadata and an external deployment-to-release association by default | No additional SBOM copy |

**Documented behaviour:** An ordinary project can also be a parent, but its metrics describe its own inventory and do not roll up child projects. A collection has no classifier, components, services, or dependency graph, and rejects SBOM uploads. A project containing components or services cannot simply be converted into a collection. These distinctions are defined in the [project concepts][projects] and [organisation guide][organizing].

A separately released product bundle with its own SBOM can therefore be an ordinary project, but it should not be confused with the product's governance collection. Keep bundle and service metrics separately identified to avoid treating repeated dependencies as distinct unique vulnerabilities across the organisation.

The project hierarchy is not a software dependency graph. A service consuming a library or another service does not establish a project-to-project dependency; dependency relationships belong inside SBOMs or an external software catalogue. A project has only one parent, so the same release record cannot be a child of independent product, production, and test collections simultaneously. [Project concepts][projects] document both limitations.

### 2.3. Collection Aggregation

**Documented behaviour:** Each collection selects among its **direct children**, using one of the following [collection logic values][project-reference].

| Native value | Selection | Suitable reporting question |
| --- | --- | --- |
| `AGGREGATE_DIRECT_CHILDREN` | All direct children | What is the combined state of this chosen group? |
| `AGGREGATE_DIRECT_CHILDREN_WITH_TAG` | Direct children carrying the configured `collectionTag` | Which child releases are labelled as deployed in production? |
| `AGGREGATE_LATEST_VERSION_CHILDREN` | Direct children with `isLatest=true` | What is the state of the explicitly selected latest release of each name? |

Nested collections compose their selection rules at each level. An organisation collection can select group collections, which select product collections, which select service collections. The service collection then selects release records. Setting a tag filter at the product level tests the service collections' tags; it does not search all descendant release tags. Similarly, a latest filter on a product whose immediate children are stable collections tests those collections' flags, not the flags of releases below them.

**Supplementary implementation evidence:** The [5.0.4 metrics implementation][metrics-source] traverses selected children recursively only through collection projects, applies each collection's own filter, excludes inactive children, and sums the selected ordinary projects' metrics. An ordinary parent stops that traversal. This substantiates the nested model while preserving the documented direct-child selection rule. The prose guide's illustrative product/service/environment patterns should not be interpreted as support for recursive tag searches.

**Recommendation:** Use all-direct-children logic above service collections and choose a deliberate release selector at each service collection. Name the resulting report by its selection criterion. Latest-release health, all-supported-release exposure, and production exposure answer different questions.

Collections aggregate metrics rather than synthesising a combined SBOM or a new analysis context. The same vulnerability present in two contributing releases can contribute to both release counts; the result is not a count of unique organisation-wide vulnerability identifiers. The [metrics documentation][metrics] also excludes collection projects from precomputed portfolio totals to avoid counting their rollups again.

### 2.4. Tags and Properties

**Documented behaviour:** [Tags][tags] are shared, many-to-many labels used for project filtering, policy assignment, alerts, and tag-filtered collections. They have no native namespace, value type, or per-tag access control. Project properties instead contain a group, name, value, type, and optional description. Neither representation grants project access.

**Recommendation:** Use tags for cross-cutting selection, including environment membership and policy categories. Use typed properties for catalogue identifiers, ownership, repository locations, artifact digests, and reconciliation timestamps. Populate them explicitly on the records that consumers inspect; parentage is not a substitute for metadata propagation.

There is a documentation qualification: the project and tag concept pages describe properties as passive metadata, while the [policy schema][policy-schema] exposes `project.properties` to [condition expressions][policy-expressions]. This architecture uses tags for documented built-in scoping and treats property-based expressions as an explicit, version-validated extension. It assumes no automatic policy, collection, or authorisation behaviour from an ownership or environment property.

## 3. Releases and Environments

A release identifies a retained software inventory. An environment describes where that inventory is used. Their relationship is many-to-many and changes independently of release creation.

### 3.1. Retained Release Inventories

**Documented behaviour:** Uploading another SBOM to the same project reconciles its component inventory: matching components and their audit decisions remain, removed components disappear, and new components are added. It does not create another retained release inventory. Creating a new project version preserves the earlier release separately. Cloning can copy selected metadata, inventories, findings, audit histories, policy violations, and ACLs. [Managing project versions][versions] describes these choices.

**Recommendation:** Create one ordinary project for each retained release and import its SBOM there. Use an in-place project only for intentionally rolling inventories such as an unreleased development line. Treat released inventories as immutable by organisational procedure, while allowing controlled corrections; Dependency-Track's upload capability does not itself enforce immutability.

Keep releases active while continued tracking is required, including older releases still deployed or supported. `active` does not mean production, and `isLatest=false` does not mean inactive. Retire records only under an explicit lifecycle policy. Inactive records retain data until deletion, but [retention][retention] can permanently remove their inventories and audit histories. Retention by version count follows retirement recency, not semantic version ordering. Archive required evidence separately before deletion.

### 3.2. Promotion and Independent Contexts

The following decision rules are architectural recommendations.

| Situation | Project records | Operational consequence |
| --- | --- | --- |
| Same release, identical inventory and shared analysis decisions, in several environments | One release project with several environment tags | One SBOM and one triage context; promotion updates metadata. |
| Different retained release | Another version of the same project name | Inventories and release-specific findings remain independently inspectable. |
| Environment-specific build, packaging, or dependency inventory | Separate artifact or variant release project | Each materially different inventory has its own SBOM. |
| Identical inventory but independently required triage, suppression, or access decisions | Separate context-specific project per release | Duplicate inventory and analysis work, with independent audit decisions and ACL placement. |
| Requirement only for additional dashboard slices | Metadata plus reporting over existing UUIDs | Avoid multiplying inventories merely to obtain another view. |

For the same artifact promoted from development to test and production, retain its UUID and version. Reconcile its complete set of current environment tags from the deployment source of truth. Add `env:prod` on production deployment; remove `env:dev` only when that release is no longer deployed anywhere classified as development. Multiple regions or replicas must not cause premature tag removal.

When independent project contexts are necessary, use separate names such as `org-a.product-a.service-1.prod` and `org-a.product-a.service-1.test`, with the actual release number in `version`. This convention keeps release and environment distinct and permits one latest pointer per context-specific name. Record a common artifact identity or digest in properties to link the copies externally. Duplicate the SBOM deliberately and do not copy context-dependent suppressions without review.

An environment tag is a current-state label. Dependency-Track does not directly model a deployment record with cluster, region, rollout interval, replica count, and the associated release UUID. Maintain that relation and its history in a deployment catalogue or reporting system. Native project tags and properties provide a projection of that data rather than a deployment ledger.

### 3.3. Analysis and Reporting

**Documented behaviour:** A [vulnerability finding][findings] relates a component in a project to a vulnerability and carries analysis decisions and audit history. [Component policies][component-policies] evaluate components during project analysis, while [vulnerability policies][vulnerability-policies] apply decisions to findings. Policy assignment can target projects, explicitly include descendants, or select project tags; collection membership alone is not a policy assignment rule. The [assignment reference][policy-reference] describes those scopes.

**Consequence:** A release tagged for both development and test still has one project's findings and policy violations. Tags do not create independent per-environment outcomes. Separate projects are warranted when two environments need conflicting analysis decisions or independent violation histories; otherwise duplication increases storage, analysis load, notifications, and reconciliation effort.

Policy edits do not immediately rerun analysis. Ensure reanalysis after changes that affect policy scope or deployment context, and wait for completion before relying on release-gating results. An old release remains relevant when deployed even if it is absent from a latest-release collection.

**Recommendation:** Produce production-exposure reports by selecting canonical release UUIDs with current production membership, then reading their findings and metrics. A tag-filtered collection provides this view only where the relevant releases are its direct children. In a nested service model, either configure every service collection for production membership or use an external report for the additional view.

Creating sibling collections named `latest` and `prod` does not give them shared children or portfolio-wide tag queries. Simultaneous native trees would require separate project copies with distinct identities, or a different hierarchy. Prefer external report projections when the inventory and analysis context are unchanged. Define whether each report counts release occurrences, distinct vulnerabilities, or deployment instances; summing environment reports can count a release deployed in both environments twice.

## 4. Access Control

An ownership hierarchy and an enforceable access boundary are separate concerns. The [access-control documentation][access] distinguishes principal capabilities from the projects on which those capabilities can be exercised.

### 4.1. Permissions and Project Access

**Documented behaviour:** Teams group users and hold permissions; users may also hold direct permissions. Effective permissions are the union of direct grants and all team grants. Coarse-grained permissions imply their fine-grained variants. Without PAC, `VIEW_PORTFOLIO` allows visibility across the portfolio. With PAC enabled, project operations require both the relevant permission and access through a team's project access control list (ACL) assignment.

ACL assignments flow down the entire parent hierarchy to current and future descendants. A child cannot deny an inherited grant; revocation must remove the granting ancestor assignment or change the hierarchy. Access does not flow upward to ancestors or sideways to siblings. `PORTFOLIO_ACCESS_CONTROL_BYPASS` bypasses project ACL restrictions. Tags, classifiers, names, and ownership properties do not replace these controls.

Permissions are global to the principal, not attached to individual ACL grants. A user with product-wide read access from one team and service-management permissions from another can exercise those management permissions throughout the accessible product. Separate permission teams and access teams simplify administration but do not provide different permission levels per project for the same principal.

### 4.2. Team Boundaries

The following assignments are recommendations using the [v5 permissions reference][permissions].

| Team purpose | ACL placement | Suggested capabilities |
| --- | --- | --- |
| Product governance reader | Product collection | `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`, `VIEW_POLICY_VIOLATION` |
| Product manager | Product collection | Reader capabilities plus explicitly required portfolio update or analysis permissions |
| Service maintainer | Its service collection | Reader capabilities, `BOM_UPLOAD`, `PORTFOLIO_MANAGEMENT_UPDATE`, and required analysis permissions |
| Service upload automation | Its service collection or pre-provisioned release projects | `BOM_UPLOAD`; add read capabilities only when the workflow needs them |
| Access administrator | Controlled administrative scope | Access-management permissions and any justified portfolio bypass |

Use `VULNERABILITY_ANALYSIS_UPDATE` for vulnerability decisions and `POLICY_VIOLATION_ANALYSIS` for policy-violation decisions where required. Do not grant create, delete, global policy management, access management, or portfolio bypass merely to upload and triage a service's SBOMs. If project creation is delegated, add the relevant create permission explicitly.

A service team that must see only its own service must not receive an ACL assignment on the product, group, or organisation ancestor. A product team assigned to the product can govern all descendant services. Collection filters do not narrow inherited ACLs: a team assigned to a latest-release collection can still access older descendant releases.

If one human needs product-wide reading but writing only within one service, the native permission composition cannot enforce that distinction through additional teams. Use separately authenticated principals with distinct memberships, a controlled management workflow, or a stronger isolation boundary. Separate instances may be appropriate when independent administrative domains are required; a grouping collection is not a tenant boundary.

### 4.3. Provisioning and Maintenance

**Recommendation:** Provision projects with their parent, required metadata, and ACLs before issuing upload credentials. Under PAC, missing assignments can make existing or newly created projects inaccessible. The [access guide][access] documents creation-time defaults, including automatic team selection for automated creation; a default selection is not an ownership policy. Restrict each automation identity to the intended access domain and reconcile assignments explicitly.

For the existing version baseline, a dedicated team API key carries that team's permissions and access. Service accounts can be evaluated after a supported upgrade; the unreleased 5.2 documentation must not be treated as a current installation prerequisite.

Validate representative access after provisioning or reparenting: a product reader can inspect its product releases, a service maintainer can upload and triage only within its service, and a sibling service remains inaccessible. Check combined team memberships and direct permissions as well as the project's own ACL. Keep hierarchy and ACL administration controlled, since moving a project can change inherited access.

## 5. Naming and Metadata Conventions

The following conventions distinguish native fields from local semantics. Stable catalogue identifiers are preferable to mutable department names in release-family identity.

| Concern | Native representation | Local convention |
| --- | --- | --- |
| Project identity | UUID; globally unique name/version pair | Store UUIDs in integrations and retain stable names across releases. |
| Release-family name | `name` | `org-a.product-a.service-1`; lowercase identifiers separated by dots. |
| Collection name | `name` on a collection project | `org-a`, `org-a.group-a`, `org-a.product-a`, `org-a.product-a.service-1.releases`. |
| Release version | `version` | Actual artifact release, such as `1.2.0`; no environment suffix by default. |
| Collection version | Optional `version` | Leave unset; do not invent a release number for an ownership group. |
| Artifact kind | `classifier` | `APPLICATION` for the example's application inventory; `LIBRARY` or `CONTAINER` for those artifacts. Collections have no classifier; `SERVICE` is not used as a classifier. |
| Latest release | `isLatest` | Latest approved release in the family, independent of deployment environment. |
| Lifecycle | `active` | True while supported or deployed and requiring continued tracking. |
| Descriptive group | Native `group` field | Preserve ecosystem grouping if useful; it is not an ACL team or an organisational parent. |
| Selection labels | Tags | `org:org-a`, `product:org-a.product-a`, `env:prod`, `criticality:high`. Prefixes are literal naming conventions, not native namespaces. |
| Environment identifiers | No native deployment-environment entity | Controlled vocabulary `dev`, `test`, `stage`, `prod`; attach one `env:` tag per current membership. |
| Ownership | Typed project properties | Group `ownership`, names `organisation-id`, `group-id`, `product-id`, `service-id`, `team-id`, type `STRING`. |
| Traceability | Typed project properties | Group `artifact`, name `digest`, type `STRING`; group `source`, name `repository`, type `URL`. |

Property groups are namespaces for property keys, not organisational groups. An `ownership/team-id` value names a catalogue or team identifier by local agreement; it neither creates the team nor adds it to an ACL. Keep automation responsible for synchronising such metadata and access assignments as distinct operations.

Example: A property request body for the service owner, using fields from the [project-property API schema][openapi].

```json
{
  "groupName": "ownership",
  "propertyName": "team-id",
  "propertyValue": "service-1-maintainers",
  "propertyType": "STRING"
}
```

## 6. Worked Example

Example: Organisation A contains Group A, Product A, and Service 1. Release `1.2.0` is deployed in `prod`; release `1.3.0` is deployed in both `dev` and `test`. Both releases remain active and retain separate inventories. The application SBOM is identical across the two environments using `1.3.0`, and those environments share analysis decisions.

### 6.1. Project Records

The identifiers below are explanatory aliases for distinct server-assigned UUIDs. An unset value means the field is omitted or empty as supported by the interface, not the literal string `unset`.

| Alias | Project name | Version | Parent | Classifier | SBOM |
| --- | --- | --- | --- | --- | --- |
| `O` | `org-a` | Unset | None | None; collection | None |
| `G` | `org-a.group-a` | Unset | `O` | None; collection | None |
| `P` | `org-a.product-a` | Unset | `G` | None; collection | None |
| `S` | `org-a.product-a.service-1.releases` | Unset | `P` | None; collection | None |
| `R120` | `org-a.product-a.service-1` | `1.2.0` | `S` | `APPLICATION` | Release `1.2.0` inventory |
| `R130` | `org-a.product-a.service-1` | `1.3.0` | `S` | `APPLICATION` | Release `1.3.0` inventory, uploaded once |

| Alias | Collection logic | Collection tag | `active` | `isLatest` |
| --- | --- | --- | --- | --- |
| `O` | `AGGREGATE_DIRECT_CHILDREN` | Unset | `true` | `false` |
| `G` | `AGGREGATE_DIRECT_CHILDREN` | Unset | `true` | `false` |
| `P` | `AGGREGATE_DIRECT_CHILDREN` | Unset | `true` | `false` |
| `S` | `AGGREGATE_LATEST_VERSION_CHILDREN` | Unset | `true` | `false` |
| `R120` | Unset; ordinary project | Unset | `true` | `false` |
| `R130` | Unset; ordinary project | Unset | `true` | `true` |

All native `group` fields are left unset in this example; business group membership is represented explicitly below. The flags on collections do not select a release: the all-children parents include those collections regardless of their latest flags, and `S` selects its direct release children.

### 6.2. Tags and Ownership Properties

Define the following tag sets as local shorthand. They are attached explicitly to each record; the notation does not imply inherited tags.

| Set | Tags |
| --- | --- |
| `T-O` | `org:org-a` |
| `T-G` | `T-O` plus `group:org-a.group-a` |
| `T-P` | `T-G` plus `product:org-a.product-a` |
| `T-S` | `T-P` plus `service:org-a.product-a.service-1` |

Every property in the next table has group `ownership` and type `STRING`. Each row lists the keys actually stored on that project; repeated values are intentional denormalisation for integration queries.

| Alias | Attached tags | Ownership property values |
| --- | --- | --- |
| `O` | `T-O` | `organisation-id=org-a`; `team-id=organisation-a-governance` |
| `G` | `T-G` | `organisation-id=org-a`; `group-id=group-a`; `team-id=group-a-governance` |
| `P` | `T-P` | `organisation-id=org-a`; `group-id=group-a`; `product-id=product-a`; `team-id=product-a-governance` |
| `S` | `T-S` | `organisation-id=org-a`; `group-id=group-a`; `product-id=product-a`; `service-id=service-1`; `team-id=service-1-maintainers` |
| `R120` | `T-S`, `env:prod` | Same ownership properties as `S` |
| `R130` | `T-S`, `env:dev`, `env:test` | Same ownership properties as `S` |

No environment tag is attached to `S`, `P`, `G`, or `O`: each is an ownership/aggregation object rather than a deployment. The external deployment catalogue records the three memberships `R120 → prod`, `R130 → dev`, and `R130 → test`. It remains the authority for their start/end times and individual deployment locations.

### 6.3. Team Access

PAC is enabled. `product-a-governance` holds the reader capabilities from Section 4.2. `service-1-maintainers` holds those reader capabilities plus `BOM_UPLOAD`, `PORTFOLIO_MANAGEMENT_UPDATE`, `VULNERABILITY_ANALYSIS_UPDATE`, and `POLICY_VIOLATION_ANALYSIS`. Neither team has bypass, access-management, create, or delete permissions. Memberships are disjoint for this example.

| Project | Direct ACL teams | Inherited ACL teams | Effective access for the example teams |
| --- | --- | --- | --- |
| `O` | None | None | Neither team; controlled administrators only |
| `G` | None | None | Neither team; controlled administrators only |
| `P` | `product-a-governance` | None | Product governance reads the product |
| `S` | `service-1-maintainers` | `product-a-governance` from `P` | Product governance reads; service maintainers manage within their permissions |
| `R120` | None | Both teams from ancestors | Governance reads; service maintainers upload and triage |
| `R130` | None | Both teams from ancestors | Governance reads; service maintainers upload and triage |

The ownership properties on `O` and `G` do not grant their named owners access. An administrator can explicitly add organisation or group governance teams when such broad descendant access is intended. A service maintainer cannot read `P` merely because `S` is accessible, and cannot access a future sibling service under `P`. Product governance can read that sibling through its parent grant. If product governance also needs management rights, granting them expands management to all accessible product descendants.

Changing which release contributes to a collection does not change this ACL table. Both `R120` and `R130` remain accessible to their teams even though only one contributes to the latest-release aggregate.

### 6.4. Aggregate Membership

Assuming both SBOM imports and analyses have completed, the configured hierarchy has the following contributing inventories. Additional products and services are omitted from this example.

| View | Selection path | Contributing releases |
| --- | --- | --- |
| Service collection `S` | Latest direct release child | `R130` only |
| Product collection `P` | All direct children, including `S` with its own selector | `R130` only |
| Group collection `G` | All direct children through `P` and `S` | `R130` only |
| Organisation collection `O` | All direct children through `G`, `P`, and `S` | `R130` only |
| Production-exposure report | External selection of canonical releases carrying `env:prod` | `R120` only |
| Development-exposure report | External selection of canonical releases carrying `env:dev` | `R130` only |
| Test-exposure report | External selection of canonical releases carrying `env:test` | `R130` only |
| Retained-release inventory report | Explicit enumeration of both retained release UUIDs | `R120` and `R130` |

The latest hierarchy excludes production release `1.2.0` because `1.3.0` is the selected latest release. It must not be labelled a production-risk report. The two non-production deployments do not duplicate `R130` in the latest hierarchy.

Two alternative configurations demonstrate the native collection choices; they replace `S`'s selector rather than creating shared-parent memberships:

| Alternative configuration on `S` | Result on `S`, `P`, `G`, and `O` |
| --- | --- |
| `AGGREGATE_DIRECT_CHILDREN_WITH_TAG`, `collectionTag=env:prod` | `R120` contributes; `R130` does not. Latest flags are unchanged. |
| `AGGREGATE_DIRECT_CHILDREN` | Both active releases contribute; repeated dependency exposure can appear in both inventories. |

If `1.3.0` is later also promoted to production, add `env:prod` to `R130`. Keep it on `R120` while any production deployment still uses that release. A production selector then includes both during the overlap, while the latest selector still includes only `R130`. Deployment timing remains external; metrics history alone does not establish historical deployment membership.

## 7. Architecture Comparison and Recommendation

The choice of hierarchy determines reporting convenience and ACL maintenance cost. Inventory multiplicity should follow retained releases and genuinely independent contexts rather than the number of labels required for reports.

### 7.1. Viable Models

| Model | Native structure | Advantages | Limitations and operational cost |
| --- | --- | --- | --- |
| Compact product hierarchy | Product collection → ordinary release projects; organisation, group, and service identifiers in metadata | Fewer collections; a product's direct-child latest or production selector operates on release records | Service ACLs must be assigned to every release; all service releases require consistent provisioning; alternate reporting views still need external selection. |
| Ownership hierarchy with service collections | Optional organisation/group collections → product → service collection → release projects | Stable service access boundary; new releases inherit both service and product access; nested reporting composes explicitly | More grouping records and reparenting governance; selectors must be correct at each level; one tree cannot provide arbitrary simultaneous report slices. |
| Independent environment contexts | Service grouping → environment-specific release families | Separate inventories, triage decisions, and environment ACL boundaries | Duplicate SBOMs for identical artifacts; more analyses, audit work, and lifecycle operations; cross-environment totals need deliberate deduplication. |

For `R` retained releases and `H` useful ownership collections, the recommended model uses `R + H` projects. A compact model with `P` product collections uses approximately `R + P`. Independent environment contexts use the sum of retained release/context combinations plus their grouping records, approaching `R × E + H` when every release has `E` separate environment contexts. These are architecture counts, not measured Dependency-Track performance estimates.

The compact model is viable when provisioning reliably assigns service ACLs to each new release and there is little value in service-level rollups. The ownership hierarchy is preferable when many service teams require stable isolation across a growing release history. Environment-specific projects are an exception justified by independent inventories, analysis, or access requirements.

### 7.2. Recommended Reference Architecture

Adopt the ownership hierarchy with **one canonical ordinary project per retained artifact release**, a stable service collection for access inheritance, and a product collection for governance. Add organisation and group collections only when they supply a real aggregate or shared access boundary; otherwise represent those logical levels in metadata.

Use latest-release selection for an explicitly named engineering-health view, with all-child aggregation above it. Maintain production membership independently, including simultaneous old and new releases during rollouts. Prefer reporting over canonical UUIDs for additional environment views; use a production-tag selector on service collections when production is the hierarchy's chosen native view.

Operational ownership should cover four distinct responsibilities:

1. Provision stable identities, parent relationships, and ACLs before SBOM ingestion.
2. Create release records, import the matching SBOMs, and update the latest flag under an explicit release policy.
3. Reconcile deployment tags from the deployment catalogue and reanalyse when policy context changes.
4. Review effective permissions, aggregate membership, and retention eligibility as the portfolio evolves.

This architecture preserves both release inventories in the worked example, supports product governance and service-scoped operations, and avoids multiplying inventories when the same artifact moves between environments. It leaves deployment history, arbitrary overlapping report groups, and per-project permission levels for one principal to explicit external processes or stronger isolation where required.

## 8. References

- Sentenz [Dependency-Track Application](../apps/dependency-track/README.md) documentation.
- Sentenz [Vendored Dependency-Track Chart](../vendor/helm/dependency-track-2.0.0/dependency-track/Chart.yaml) configuration.
- Dependency-Track [Documentation Revision][docs-revision] repository revision.
- Dependency-Track [About Projects][projects] documentation.
- Dependency-Track [Projects Reference][project-reference] documentation.
- Dependency-Track [Organizing Projects into Hierarchies][organizing] documentation.
- Dependency-Track [Managing Project Versions][versions] documentation.
- Dependency-Track [About Tags][tags] documentation.
- Dependency-Track [About Access Control][access] documentation.
- Dependency-Track [Permissions][permissions] documentation.
- Dependency-Track [About Changes in v5][v5-changes] documentation.
- Dependency-Track [Breaking Changes in v5][api-changes] documentation.
- Dependency-Track [Upgrading to v5.1.0][upgrade-51] documentation.
- Dependency-Track [Upgrading to v5.2.0][upgrade-52] documentation.
- Dependency-Track [Configuring Project Retention][retention] documentation.
- Dependency-Track [About Vulnerability Findings][findings] documentation.
- Dependency-Track [About Component Policies][component-policies] documentation.
- Dependency-Track [About Vulnerability Policies][vulnerability-policies] documentation.
- Dependency-Track [Component Policy Assignment][policy-reference] documentation.
- Dependency-Track [Policy Condition Expressions][policy-expressions] documentation.
- Dependency-Track [Policy Schema][policy-schema] documentation.
- Dependency-Track [About Time Series Metrics][metrics] documentation.
- Dependency-Track [REST API v1 OpenAPI Schema][openapi] specification.
- Dependency-Track [Version 5.0.4 Metrics Implementation][metrics-source] source code.

[docs-revision]: https://github.com/DependencyTrack/docs/commit/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a
[projects]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/projects.md
[project-reference]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/projects.md
[organizing]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/guides/user/organizing-projects.md
[versions]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/guides/user/managing-project-versions.md
[tags]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/tags.md
[access]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/access-control.md
[permissions]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/permissions.md
[v5-changes]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/changes-in-v5.md
[api-changes]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/api/v5-breaking-changes.md
[upgrade-51]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/guides/upgrading/v5.1.0.md
[upgrade-52]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/guides/upgrading/v5.2.0.md
[retention]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/guides/administration/configuring-project-retention.md
[findings]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/vulnerability-findings.md
[component-policies]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/component-policies.md
[vulnerability-policies]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/vulnerability-policies.md
[policy-reference]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/policies/component-policies.md
[policy-expressions]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/policies/condition-expressions.md
[policy-schema]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/policies/schema.md
[metrics]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/time-series-metrics.md
[openapi]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/api/openapi-v1.yaml
[metrics-source]: https://github.com/DependencyTrack/dependency-track/blob/5.0.4/apiserver/src/main/java/org/dependencytrack/persistence/jdbi/MetricsDao.java
