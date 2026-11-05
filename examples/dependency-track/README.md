# Dependency-Track Configuration Examples

Dependency-Track configuration as code expresses policy definitions, software bill of materials (SBOM) organisation, and Portfolio Access Control (PAC) as version-controlled inputs. These examples implement the data model from the [SBOM organisation reference architecture](../../docs/dependency-track-sbom-organisation.md), including release `1.2.0` in production and one `1.3.0` inventory shared by development and test.

Policy as Code (PaC) uses native vulnerability-policy YAML and REST-managed component policies. Organisation, deployment membership, and PAC files define a **local declarative format** for an API reconciler. This directory contains example configuration and an API mapping contract; it does not include a live reconciler or install Kubernetes custom resources.

- [1. Formats and Version Scope](#1-formats-and-version-scope)
- [2. SBOM Organisation](#2-sbom-organisation)
- [3. Policy as Code](#3-policy-as-code)
  - [3.1. Component Policy](#31-component-policy)
  - [3.2. Vulnerability Policy Bundle](#32-vulnerability-policy-bundle)
- [4. Portfolio Access Control](#4-portfolio-access-control)
- [5. API Mapping and Reconciliation](#5-api-mapping-and-reconciliation)
- [6. Expected Results](#6-expected-results)
- [7. References](#7-references)

## 1. Formats and Version Scope

The examples use the [documentation revision][docs-revision] `d46daa5c13c1abba24b29e6425beb6b1f0fbf12a`, inspected on 2026-09-27. The repository's bundled application baseline is `5.0.4`. Native bundle configuration, the PAC setting, and component-policy creation behaviour were also checked against the `5.0.4` implementation. API payloads and permissions should be checked against the installed server's schema before integration; the documentation includes later v5 changes.

| File | Format | Consumer |
| --- | --- | --- |
| [organisation.yaml](organisation.yaml) | Local `portfolio-v1` declaration | A reconciler managing projects, parents, tags, and properties |
| [deployments.yaml](deployments.yaml) | Local `deployments-v1` declaration | A deployment-to-project metadata reconciler |
| [access-control.yaml](access-control.yaml) | Local `access-v1` declaration | A privileged reconciler managing teams, permissions, ACLs, and the PAC setting |
| [production-severity.yaml](policies/component/production-severity.yaml) | Local `component-policy-v1` envelope | A reconciler submitting native policy and condition request bodies |
| [production-triage.yaml](policies/vulnerability/production-triage.yaml) | Native vulnerability-policy YAML | Dependency-Track's ZIP bundle synchroniser |
| [application.properties](application.properties) | Native API-server property fragment | The API server's configuration mechanism |

The `format`, `id`, `parentRef`, `projectRef`, `teamRef`, `scope`, and request-envelope fields are local conventions. Dependency-Track cannot import the complete local YAML files directly. They are not Helm values or Kubernetes resource definitions. The native property fragment must be merged into the server's existing configuration rather than replacing the full file.

## 2. SBOM Organisation

[organisation.yaml](organisation.yaml) declares six project records. Each `project` object contains native project fields; the surrounding `id`, `parentRef`, and `properties` describe how a reconciler connects records and calls separate endpoints. YAML aliases reuse the service ownership property list, expanding it onto each release without relying on native metadata inheritance.

| Local identifier | Representation | Parent | SBOM placement |
| --- | --- | --- | --- |
| `organisation-a` | Organisation collection | None | None |
| `group-a` | Group collection | `organisation-a` | None |
| `product-a` | Product collection | `group-a` | None |
| `service-1` | Latest-release collection | `product-a` | None |
| `service-1-1-2-0` | Ordinary application project, version `1.2.0` | `service-1` | Release `1.2.0` SBOM |
| `service-1-1-3-0` | Ordinary application project, version `1.3.0` | `service-1` | Release `1.3.0` SBOM |

Collections have no version or classifier. Both release projects are active, share the same native `name`, and have different version strings. Only `1.3.0` has `isLatest: true`. A build pipeline uploads the actual release SBOM to its resolved project UUID; inventory generation is separate from these organisation declarations.

[deployments.yaml](deployments.yaml) is the source for the current environment memberships in this example. Its `memberships` entries reference the ordinary release records and produce `env:` tags. The tags in `organisation.yaml` are the corresponding initial snapshot. In a live integration, one deployment reconciler should own the `env:` prefix; the organisation reconciler should preserve those runtime tags while maintaining its own structural tags. The checked-in snapshot is not a second continuous writer.

Promotion adds membership to an existing release. Remove an environment tag only after the release has no deployments remaining in that environment. The snapshot does not model rollout history, regions, replicas, or timestamps; an external deployment catalogue supplies those facts.

## 3. Policy as Code

Component policies raise violations, while vulnerability policies manage finding analysis. Their configuration mechanisms and operational effects differ. Both examples select production releases by `env:prod`, independently of latest-release collection membership.

### 3.1. Component Policy

[production-severity.yaml](policies/component/production-severity.yaml) declares a policy with two native conditions. Operator `ANY` raises a `FAIL` violation when a component has a `HIGH` or `CRITICAL` vulnerability. `onlyLatestProjectVersion: false` keeps older production release `1.2.0` eligible.

The `policy` object is the create request body. Each `conditions[].request` is a separate condition-create body. Condition `id` values are local reconciliation identifiers, not server fields. The `scope.tags` list is applied through the tag-assignment endpoint; placing tags or conditions into a create request alone is insufficient. The [5.0.4 policy resource][policy-source] creates the core policy fields separately from its conditions and assignments.

Create the policy without conditions, attach `env:prod`, and then add conditions. A policy without project or tag assignments is portfolio-wide, so scope should be established before adding active conditions. Tag assignments are alternatives, not a conjunction: adding a product tag alongside `env:prod` broadens scope. This example intentionally covers all production-tagged projects; product-specific restrictions require a deliberate condition or different assignment design.

The `FAIL` result does not itself stop a deployment. A release gate must wait for analysis completion, read the project's policy violations, and enforce its decision. Policy edits require a subsequent project analysis before updated results are available.

### 3.2. Vulnerability Policy Bundle

[production-triage.yaml](policies/vulnerability/production-triage.yaml) follows the [native v1 policy schema][policy-schema] and contains a Common Expression Language (CEL) condition. It observes high and critical findings on production-tagged projects. `operationMode: LOG` records matches without applying the supplied analysis or changing suppression. Moving to `APPLY` would set matching findings to `IN_TRIAGE`; that change requires an explicit policy decision, including consideration of existing triage states.

Example: Package only native vulnerability-policy files at the ZIP root, from the repository root, using Python's standard library.

```bash
python3 - <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

source = Path("examples/dependency-track/policies/vulnerability")
destination = Path(".local/dependency-track/vulnerability-policies.zip")
destination.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(destination, "w", compression=ZIP_DEFLATED) as bundle:
    for path in sorted(source.glob("*.yaml")):
        bundle.write(path, arcname=path.name)
print(destination)
PY
```

Publish the ZIP at a versioned HTTP(S) location, then replace the example URL in [application.properties](application.properties). If authentication is required, provide `DT_VULN_POLICY_BUNDLE_AUTH_BEARER_TOKEN` through the existing secret mechanism. The configured synchronisation schedule runs every 15 minutes. The bundle synchroniser validates the YAML schema and compiles CEL on the server; local YAML parsing alone does not establish that CEL validation passed.

Bundle synchronisation creates and updates bundle-managed policies and removes policies omitted from a later bundle. Publish the complete intended bundle, rather than a partial per-policy update. User-managed policies are not overwritten, and a collision with a user-managed policy name causes the sync to fail. Organisation, PAC, and component-policy envelopes must not be packaged in this ZIP.

## 4. Portfolio Access Control

[access-control.yaml](access-control.yaml) declares the native PAC setting, three teams, their permissions, and direct project grants. The `access-management` / `acl.enabled` setting is verified in the [5.0.4 configuration constants][config-source]. Property values are strings, so the configured Boolean value is written as `"true"`.

| Team | Direct project grant | Effective boundary | Capabilities |
| --- | --- | --- | --- |
| `product-a-governance` | `product-a` | Product and all descendants | Read inventory, vulnerabilities, and policy violations |
| `service-1-maintainers` | `service-1` | Service collection and both retained releases | Read, upload SBOMs, update projects, and triage findings/violations |
| `service-1-upload` | `service-1` | Pre-provisioned releases under the service | Upload SBOMs only |

The upload team needs each target UUID supplied by provisioning. It has no project-creation or read permission; a pipeline that also queries policy results needs separately granted read capabilities. Service maintainers receive no delete, access-management, or portfolio-bypass permission. Properties naming an ownership team do not create a grant; only the three entries in `grants` establish direct access in this example. Organisation and group collections remain restricted to controlled administrators unless additional grants are deliberately declared.

Bind human identities to the appropriate teams through the existing identity-management process. Use a dedicated team API key for upload automation on the `5.0.4` baseline. Service accounts are not a prerequisite; the pinned documentation describes them for unreleased `5.2.0`.

Team capabilities combine globally with all accessible projects. A principal belonging to both governance and service-maintainer teams gains the maintainer capabilities throughout the accessible product. Separate memberships or separately authenticated principals are required when product-wide reading and service-only writing must remain distinct. Collection filters never narrow inherited ACLs.

## 5. API Mapping and Reconciliation

The following mapping defines how an implementation consumes the local files. Paths are relative to the server's `/api` base. The API exchanges JSON; parse YAML locally and serialise only the relevant native objects as JSON.

| Declaration | Native operation | Required translation |
| --- | --- | --- |
| `teams[]` | `PUT /v1/team` | Send `name`; retain the returned team UUID. |
| Team permissions | `PUT /v1/permission/team` | Send `team` as the resolved UUID and `permissions` as the declared string list. |
| `projects[].project` | `PUT /v1/project` | Send native fields; add `parent: {uuid: ...}` after resolving `parentRef`. Persist returned UUIDs. |
| Project direct grants during creation | `accessTeams` in the project create request | Supply the intended direct team UUIDs; verify creator defaults do not introduce unintended grants. |
| Existing project updates | `PATCH /v1/project/{uuid}` | Send changed fields and a resolved parent when reparenting. Omitting or nulling `parent` does not detach it. |
| `projects[].properties[]` | `PUT /v1/project/{uuid}/property`; `POST` for existing properties | Send native property bodies; identify each property by its group/name pair. |
| `grants[]` | `PUT /v1/acl/mapping` | Send `team` and `project` as resolved UUID strings. |
| `configuration[]` | `POST /v1/configProperty` | Send each native group/name/value object. |
| Component-policy `policy` | `PUT /v1/policy`; `POST` for updates | Send core fields; include the stored UUID for updates. |
| Component-policy `scope.tags[]` | `POST /v1/tag/{name}/policy` | Send an array containing the policy UUID; URL-encode the tag in the path. |
| Component-policy `conditions[].request` | `PUT /v1/policy/{uuid}/condition` | Send each native request; retain condition UUIDs for later updates. |
| Deployment memberships | Project tag update or `/v1/tag/{name}/project` operations | Reconcile only `env:` tags for the referenced release UUIDs. |

Example integration order:

1. Validate identifiers, references, acyclic parentage, unique name/version pairs, one latest flag per release family, and environment vocabulary.
2. Resolve existing objects using UUID state or exact lookups. Paginate list endpoints and reject ambiguous matches. Produce a reviewable difference before applying changes.
3. Create teams, then create collections and releases in parent-first order. Map direct access explicitly and persist the identifiers returned by the server.
4. Reconcile declared team permissions and direct ACL assignments. Inventory existing grants as well as declared ones; an add-only process cannot enforce exclusive access. Review removals and reparenting because they change inherited access.
5. Enable PAC after the required assignments are in place and before onboarding restricted principals. For an existing instance, this includes the assignment rollout for its existing projects.
6. Apply component-policy scope and conditions, publish the native vulnerability bundle, and import each release SBOM into its ordinary project.
7. Reconcile deployment membership, trigger analysis where needed, and verify effective access and aggregate membership.

These steps describe the contract for a reconciler, not commands implemented by this directory. Keep desired-state ownership explicit: the organisation process owns structural metadata, deployment automation owns environment membership, and access administration owns ACLs and permissions. Reapplying unchanged inputs should produce no writes. Missing release declarations should generate a retirement/deletion proposal rather than automatically removing retained evidence.

The bootstrap principal requires the operations it performs: portfolio creation/update, property management, policy management, and access management. The ACL mapping endpoint requires `ACCESS_MANAGEMENT`; the configuration-property endpoint requires `SYSTEM_CONFIGURATION` or its update variant. Keep those capabilities separate from the upload identity and verify endpoint requirements against the deployed version.

## 6. Expected Results

The example provides configuration inputs, not fabricated vulnerability findings. The following results describe membership and policy scope after reconciliation and SBOM analysis.

| Check | Expected result |
| --- | --- |
| Retained inventories | Two ordinary release projects; no SBOM on any collection |
| Latest aggregate at service, product, group, and organisation | Release `1.3.0` only |
| Production membership | Release `1.2.0` only |
| Development and test membership | The same `1.3.0` project UUID in both |
| Component policy eligibility | Production-tagged `1.2.0`, despite `isLatest: false` |
| Component policy result | `FAIL` only when an eligible component matches either severity condition |
| Vulnerability policy | Matching production findings logged; existing analysis state remains unchanged |
| Governance access | Product and both releases readable |
| Service-maintainer access | Both service releases manageable within granted permissions; no product-ancestor or sibling-service grant |
| Upload automation | SBOM upload to the supplied release UUIDs; no automatic project creation |

For a native production aggregate, change only the service collection to `AGGREGATE_DIRECT_CHILDREN_WITH_TAG` and add `collectionTag: {name: "env:prod"}` to its `project` object. All-child collections above it then roll up production release `1.2.0`. This replaces the hierarchy's latest view; simultaneous latest and production reporting should query canonical release UUIDs externally rather than duplicate inventories.

## 7. References

- Sentenz [Dependency-Track SBOM Organisation](../../docs/dependency-track-sbom-organisation.md) article.
- Dependency-Track [Documentation Revision][docs-revision] repository revision.
- Dependency-Track [Vulnerability Policies][vulnerability-policies] documentation.
- Dependency-Track [Component Policies][component-policies] documentation.
- Dependency-Track [Access Control][access] documentation.
- Dependency-Track [REST API v1][openapi] specification.
- Dependency-Track [Version 5.0.4 Configuration Constants][config-source] source code.
- Dependency-Track [Version 5.0.4 Policy Resource][policy-source] source code.
- Dependency-Track [Version 5.0.4 Application Properties][application-source] configuration.
- Dependency-Track [Version 5.0.4 Vulnerability Policy Schema][policy-schema] specification.

[docs-revision]: https://github.com/DependencyTrack/docs/commit/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a
[vulnerability-policies]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/policies/vulnerability-policies.md
[component-policies]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/policies/component-policies.md
[access]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/concepts/access-control.md
[openapi]: https://github.com/DependencyTrack/docs/blob/d46daa5c13c1abba24b29e6425beb6b1f0fbf12a/docs/reference/api/openapi-v1.yaml
[config-source]: https://github.com/DependencyTrack/dependency-track/blob/5.0.4/apiserver/src/main/java/org/dependencytrack/model/ConfigPropertyConstants.java
[policy-source]: https://github.com/DependencyTrack/dependency-track/blob/5.0.4/apiserver/src/main/java/org/dependencytrack/resources/v1/PolicyResource.java
[application-source]: https://github.com/DependencyTrack/dependency-track/blob/5.0.4/apiserver/src/main/resources/application.properties
[policy-schema]: https://github.com/DependencyTrack/dependency-track/blob/5.0.4/apiserver/src/main/resources/schema/vulnerability-policy-v1.schema.json
