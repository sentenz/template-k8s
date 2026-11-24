# Reconciliation contract

This document defines how a GitOps delivery system renders, validates, applies, observes, and removes the Kubernetes resources described by this project. It is independent of a particular GitOps controller and contains no controller-specific custom resources.

The contract assumes two applications (`app-a` and `app-b`) and three independent clusters (`dev`, `stage`, and `prod`). It follows the proposed `apps/`, `infrastructure/`, and `clusters/` layout. The requirements below are project policy unless explicitly attributed to upstream documentation.

**Activation status:** this is a proposed operating contract. Cluster endpoints, trust anchors, provider identities, notification destinations, and the reconciler implementation have not been supplied. They must be registered and tested before enabling writes. This document does not install or configure a reconciler.

- [1. Source of truth and ownership](#1-source-of-truth-and-ownership)
- [2. Rendering and toolchain](#2-rendering-and-toolchain)
  - [2.1. Version baseline](#21-version-baseline)
  - [2.2. Canonical rendering commands](#22-canonical-rendering-commands)
- [3. Cluster mapping](#3-cluster-mapping)
- [4. Credentials and authorization](#4-credentials-and-authorization)
- [5. Reconciliation sequence and health](#5-reconciliation-sequence-and-health)
- [6. Pruning and field ownership](#6-pruning-and-field-ownership)
- [7. Secret handling](#7-secret-handling)
- [8. Failure handling and recovery](#8-failure-handling-and-recovery)
  - [8.1. Rollback](#81-rollback)
  - [8.2. Emergency intervention](#82-emergency-intervention)
  - [8.3. Cluster recovery](#83-cluster-recovery)
- [9. Status, audit, and activation checks](#9-status-audit-and-activation-checks)

## 1. Source of truth and ownership

An approved Git commit is the desired state. The delivery system pulls the protected deployment branch, resolves it to a full commit SHA, and uses that same SHA for every phase of one reconciliation attempt. A webhook may trigger an early check; polling remains the recovery mechanism for missed events.

Environment promotion changes chart versions, image digests, and configuration through reviewed pull requests. It does not rebuild an already approved artifact. Each environment reads only its own cluster composition and referenced overlays.

| Reconciliation unit    | Desired-state root            | Owner                                     |
| ---------------------- | ----------------------------- | ----------------------------------------- |
| Controllers            | `clusters/<env>/controllers/` | Platform team                             |
| Platform configuration | `clusters/<env>/configs/`     | Platform team                             |
| Applications           | `clusters/<env>/apps/`        | Application teams, within platform policy |

`clusters/<env>/kustomization.yaml` aggregates these units for complete rendering and review. It is not reconciled as an additional owner. Every resource identity—API group, kind, namespace where applicable, and name—has exactly one reconciliation owner.

The implementation must maintain inventory per cluster and reconciliation unit. A move between units requires an ownership-transfer procedure that suppresses deletion by the previous owner. No unit may discover deletion candidates merely by listing every object in a namespace.

## 2. Rendering and toolchain

### 2.1. Version baseline

The following pins are taken from the available project configuration or local tooling; they are a proposed baseline, not a claim of a completed compatibility certification.

| Tool                 | Pin or selection rule                                                        | Role                                                 |
| -------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------- |
| Standalone Kustomize | `v5.8.1`                                                                     | Renders bases, overlays, and Helm generators         |
| Helm                 | `v4.2.4`                                                                     | Chart inflation through the Kustomize Helm generator |
| kubeconform          | `v0.7.0`                                                                     | Rendered-resource schema validation                  |
| kubectl              | Exact patch version matching each target's approved Kubernetes minor version | API validation and operational checks                |
| Reconciler           | Exact release and immutable image digest, selected during integration        | Pulling, inventory, apply, health, and prune         |

The existing Helm image pin is `alpine/helm:4.2.4@sha256:76c375eed56144c68d6197c55bc5a4552fb42002190b796729901cbab3ae6e51`. This pins the Helm image only; it does not define a complete rendering image. The locally available Helm executable failed its version check, so end-to-end rendering was not verified while preparing this document.

Before activation, record the exact kubectl patch, reconciler release, combined renderer image digest, and target Kubernetes version in the deployment integration's checked-in tool lock. Include a schema-bundle revision or digest. CI must reject unresolved fields and version mismatches. The bootstrap record must identify that lock's Git revision. Credentials do not belong in the lock.

Pin the complete renderer image by digest and use it in both CI and reconciliation. Verify distribution checksums or signatures during its build. Upgrade the toolchain through a reviewed change that renders all environments and runs integration tests. Do not silently substitute the Kustomize embedded in kubectl. Kubernetes officially supports [kubectl within one minor version of the API server](https://kubernetes.io/releases/version-skew-policy/#kubectl); the project deliberately selects the matching minor version.

### 2.2. Canonical rendering commands

Run commands from the repository root, inside the pinned renderer environment, against a clean checkout of the selected commit:

```sh
# Complete desired state for review and validation; no cluster writes.
kustomize build clusters/dev --enable-helm --helm-command helm
kustomize build clusters/stage --enable-helm --helm-command helm
kustomize build clusters/prod --enable-helm --helm-command helm

# Independently owned units consumed by the delivery integration.
kustomize build clusters/dev/controllers --enable-helm --helm-command helm
kustomize build clusters/dev/configs --enable-helm --helm-command helm
kustomize build clusters/dev/apps --enable-helm --helm-command helm
```

Substitute `stage` or `prod` consistently for the corresponding units. The Makefile should expose the same commands through `make k8s-render K8S_CLUSTER=<env>`; unit-specific targets may wrap the child roots. These are rendering operations, not deployment commands.

Write output to a temporary file, require a successful exit and nonempty expected inventory, and publish it atomically for validation. Never pipe a potentially failed render directly into a cluster write. A render failure or unexpectedly empty output must never become a pruning instruction.

Rendering requirements:

- Pin every chart version and application image digest. Published versions must be immutable and retained for rollback.
- Begin with a clean checkout without stale downloaded chart directories. Kustomize may reuse a local chart rather than fetch the requested version. For intentional vendoring, verify chart content and version against a committed checksum manifest.
- Keep default file-loading restrictions. Supply Helm values within their overlay roots; avoid enabling arbitrary execution plugins.
- When templates inspect Kubernetes capabilities, commit explicit `kubeVersion` and `apiVersions` settings supported by the pinned generator, matching the target cluster contract. Do not derive desired output from live-cluster lookups.
- Exclude Helm test hooks from continuously applied output. Kustomize's Helm generation does not supply Helm release storage, hook lifecycle, or `helm rollback`.
- Reject random, time-dependent, or externally mutable template inputs. A repeated render with identical approved inputs must produce the same desired resources.
- Validate schemas and policy before any write. Custom resources require the corresponding pinned CRD schemas; missing schemas must not be silently ignored. Target API validation additionally runs after prerequisite CRDs and admission services are ready.

The [upstream Kustomize Helm example](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/chart.md) documents chart inflation, Helm enablement, and local chart reuse.

## 3. Cluster mapping

The following names are proposed logical bindings. Context aliases must be explicitly configured; they are not evidence of a cluster's identity.

| Environment | Git root          | Operational context alias | Application namespaces       | Cluster isolation       |
| ----------- | ----------------- | ------------------------- | ---------------------------- | ----------------------- |
| Development | `clusters/dev/`   | `project-dev`             | `app-a-dev`, `app-b-dev`     | Dedicated dev cluster   |
| Staging     | `clusters/stage/` | `project-stage`           | `app-a-stage`, `app-b-stage` | Dedicated stage cluster |
| Production  | `clusters/prod/`  | `project-prod`            | `app-a-prod`, `app-b-prod`   | Dedicated prod cluster  |

Each `clusters/<env>/README.md` must register the real provider cluster identifier, API endpoint, certificate-authority trust or fingerprint, Kubernetes version, credential binding, and operations owner. The delivery integration must verify its intended target before mutation and stop on a mismatch. A recreated cluster requires explicit re-enrollment of its identity.

Never use an ambient current context for automation. Prefer one cluster-scoped execution identity per runner; manual commands must include `--context`. Namespace separation supplements these cluster boundaries and does not replace them. A shared default namespace must not be applied across an aggregate containing several application namespaces.

Ingress-controller Services retain type `LoadBalancer` in all environments. Dev must document its load-balancer implementation or alternate local access route; an unresolved external address is not automatically a healthy ingress path.

## 4. Credentials and authorization

| Access                     | Identity and minimum scope                                                                                             |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Git checkout               | Read-only repository identity; protected branch access                                                                 |
| Promotion automation       | Separate identity permitted to create promotion branches and pull requests; no approval bypass                         |
| Chart retrieval            | Read-only access to the required chart repository or registry                                                          |
| Image publishing           | CI-only identity scoped to the application's image repository                                                          |
| Chart publishing           | CI-only identity scoped to the chart repository                                                                        |
| Controller installation    | Per-cluster platform identity with the reviewed cluster-scoped and namespace permissions required by those controllers |
| Application reconciliation | Per-cluster application identity scoped to approved application namespaces and resource kinds                          |
| Secret retrieval           | Workload identity scoped to that cluster/environment and required secret paths                                         |

Prefer short-lived workload federation or projected service-account tokens over long-lived static credentials. Where federation is unavailable, inject credentials from the approved secret store and rotate them under a documented schedule. CI rendering and pull-request jobs receive no deployment credentials; untrusted pull requests receive no private credentials.

Separate publishing, promotion, and reconciliation identities. The application reconciler must not grant itself platform privileges. Bootstrap may require broader permissions, but routine reconciliation must use dedicated least-privilege roles. Store kubeconfigs, registry tokens, and private keys outside Git, rendered artifacts, and logs.

Record credential issuer, audience, expiry/renewal behavior, and rotation ownership without recording secret values. Authentication failure must stop new writes and pruning and produce a redacted alert.

## 5. Reconciliation sequence and health

Default scheduling policy: poll every 5 minutes with jitter; serialize attempts per cluster and unit. On a new revision, render and validate all units from one commit before applying any. Do not interleave an older attempt with a newer one.

1. **Preflight:** verify cluster identity, credentials, toolchain, artifact availability, policies, and expected inventory. Establish prerequisite controller namespaces before namespaced installations.
2. **Controllers:** establish required CRDs, install controllers, and wait for serving endpoints and admission webhooks. Schema presence alone is insufficient.
3. **Configuration:** establish application namespaces, RBAC, quotas, network policy, and controller-dependent configuration. Gate dependent workloads on required secret and certificate readiness.
4. **Applications:** apply workloads, observe the new resource generations, and execute the application's smoke tests.
5. **Completion:** evaluate approved pruning, recheck health, and record the successfully reconciled revision. Do not mark success based only on an accepted API request.

| Resource or capability             | Required health evidence                                                                                | Default timeout |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------- |
| CRD                                | `Established=True`; required API version served                                                         | 5 minutes       |
| Deployment                         | Current generation observed, rollout complete, required replicas updated and available                  | 10 minutes      |
| StatefulSet                        | Current generation observed; intended replicas and update strategy satisfied                            | 15 minutes      |
| DaemonSet                          | Required nodes have updated, ready pods                                                                 | 10 minutes      |
| Bootstrap or migration Job         | `Complete=True`; failure is blocking                                                                    | 15 minutes      |
| Admission/controller service       | Ready endpoints and successful representative API request or controller-specific check                  | 10 minutes      |
| Secret/certificate custom resource | Controller-specific readiness, current generation where supported, and expected target object available | 10 minutes      |
| Application endpoint               | Successful HTTP/TLS or protocol smoke test through its intended network path                            | 5 minutes       |

Overrides must be committed alongside the owning workload and justified by its startup or migration behavior. Unknown custom-resource kinds require an explicit health adapter; absence of a standard `Ready` condition must not imply success. Resources such as ConfigMaps and Roles require successful apply and dependency validation rather than a fictional readiness condition.

Example diagnostics, after substituting the actual workload name:

```sh
kubectl --context project-dev -n app-a-dev rollout status deployment/app-a --timeout=10m
kubectl --context project-dev -n app-a-dev get pods
```

A health failure stops downstream units and promotion. Already accepted writes remain; Kubernetes apply is not a multi-resource transaction. Record observed state and the failed revision before retrying or recovering.

## 6. Pruning and field ownership

Pruning deletes an object previously owned by the same reconciliation unit that is absent from its new approved inventory. It must never delete an object merely because it is absent from the repository or shares a label.

| Resource category                                                                       | Default deletion policy                                                       |
| --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Stateless application Deployments, Services, ConfigMaps, and app-specific policy        | Inventory-based pruning after successful validation, apply, and health checks |
| Namespaces, CRDs, persistent volumes/claims, StorageClasses, and stateful data services | Protected; require a separate reviewed decommission procedure                 |
| Shared cluster RBAC, admission webhooks, ingress classes, and controller installations  | Protected; platform-owned dependency review before removal                    |
| Secrets produced by an external controller                                              | Owned by that controller; excluded from the application's pruning inventory   |

The delivery adapter must enforce protections independently of labels supplied by application manifests. Initial integration starts with deletion disabled; enable routine pruning after inventory ownership and a disposable-cluster deletion test pass.

No pruning occurs after a Git, render, validation, authorization, or health failure. An intentional empty unit requires an explicit reviewed decommission change. Dependency-sensitive removals that prevent new resources becoming healthy require a staged migration, not a blanket pruning exception.

Wait for deletion completion and report stuck finalizers. Never remove finalizers automatically to force success. Retain ownership records for protected or failed deletions so that subsequent attempts cannot silently forget them.

Use a stable field manager for server-side apply when supported. Do not force ownership conflicts automatically. Delegate fields controlled by other controllers—for example, workload replicas managed by an HPA—and define narrow drift exclusions for those fields. Broad resource-level drift exclusions are prohibited.

## 7. Secret handling

The default is an external secret store with environment-scoped workload identity. Git contains references and policy, not plaintext secret values. An encrypted-in-Git alternative is acceptable only with an explicitly documented decryption integration and recovery key procedure.

For externally generated Secrets, reconcile the secret controller first, then its store/reference configuration, then wait for the required target Secrets before applying dependent workloads. Namespace and secret-store permissions must prevent cross-environment access.

For encrypted files, decrypt only in an isolated execution step backed by memory or ephemeral storage. Do not persist decrypted output in build artifacts, diffs, caches, or logs. Encryption keys and recovery material must remain available independently of the cluster being recovered.

Schema validation and diagnostics must redact secret payloads, including base64 data. Kubernetes Secret base64 encoding does not provide encryption. Enable appropriate access controls and encryption at rest as described in [Kubernetes Secret good practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/).

A secret-store outage blocks deployments that require unavailable secrets. Preserve existing resources and usable secrets; do not substitute empty values or delete them. Rotation must include the application's reload or restart behavior and a health check. Removing a secret reference requires explicit review of the secret controller's deletion policy.

## 8. Failure handling and recovery

Retry transient failures with exponential backoff starting at 30 seconds and capped at 5 minutes, with jitter. Alert after three failed attempts or a health timeout; do not wait for retries on an identity mismatch or suspected credential compromise. These timings are project defaults, configurable through reviewed integration settings.

| Failure                             | Required behavior                                                                                                                      |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Git or chart registry unavailable   | Retain running workloads; no new apply or prune. Report stale desired-state observation and retry.                                     |
| Invalid rendering or policy failure | Reject the revision before writes; retain the last successful inventory.                                                               |
| API outage or partial apply         | Record partial progress; retry idempotently from the same desired revision, or supersede it explicitly with a newer approved revision. |
| Workload health failure             | Stop dependent units, pruning, and promotion. Preserve diagnostics; recover by reviewed rollback or forward fix.                       |
| Drift in owned fields               | Restore declared values unless a recorded, time-bounded incident suspension is active.                                                 |
| Inventory loss                      | Disable pruning. Restore the inventory or perform an explicit ownership audit before resuming deletion.                                |
| Secret or credential failure        | Stop affected writes, redact diagnostics, renew or restore access, then repeat preflight.                                              |

### 8.1. Rollback

Revert the relevant chart/image pins or configuration through a reviewed Git commit, then reconcile that new commit. Record the previous and replacement commit SHAs and health results. Do not use `helm rollback` for resources produced only by Kustomize chart inflation, and do not rely on an imperative workload rollback that reconciliation would overwrite.

There is no automatic rollback for the initial contract. A failed rollout requires an explicit Git revert or forward fix. Database schema changes, persistent-data restoration, and incompatible CRD upgrades require their own migration/recovery procedures; a manifest revert does not reverse data changes.

### 8.2. Emergency intervention

An authorized operator may suspend the affected unit for a recorded incident. Document the unit, reason, owner, expiry, and incident identifier. Make the minimum intervention with an explicit cluster context, then represent the accepted state in Git or restore the declared state. Resume reconciliation, verify health, and close the suspension. Never leave an untracked permanent drift exception.

### 8.3. Cluster recovery

Recreate cluster foundations and re-enroll the target identity. Restore access to Git, immutable artifacts, secret services, and decryption/recovery keys. Restore inventory if valid for the recovered cluster; for a new cluster, begin with an empty inventory and pruning disabled. Apply controllers, configuration, and applications in the documented order, restoring persistent data before workloads that depend on it.

Validate backups by periodic restore exercises. Define RPO/RTO per data service in `docs/runbooks/disaster-recovery.md`; Git alone is not a data backup. Enable pruning only after ownership and health have been verified.

## 9. Status, audit, and activation checks

For every attempt, retain cluster identity, unit, desired commit, last successful commit, toolchain digest, non-secret render checksum, artifact pins, apply/health/prune results, timestamps, and error classification. Emit status for source freshness, health, drift, and reconciliation suspension. Send failures to an assigned environment owner through the configured alert destination; that destination remains an activation prerequisite.

Before enabling this contract, the delivery integration must demonstrate:

- Identical approved inputs produce equivalent output in CI and reconciliation, including Helm compatibility and CRD schema checks.
- All three cluster identities and exact client/tool versions are registered and verified.
- Application identities cannot mutate another environment or escalate to platform permissions.
- Controller and secret readiness gates prevent premature workload deployment.
- Missing sources, empty renders, and failed health checks cannot trigger deletion.
- Protected resources survive routine pruning, while eligible deleted manifests are removed from inventory and cluster.
- Partial apply, stale credentials, drift correction, inventory recovery, and Git rollback behave as specified.
- Secret redaction and backup/restore procedures pass their integration exercises.

This contract operationalizes the [OpenGitOps principles](https://opengitops.dev/) of declarative, versioned desired state, automated pulling, and continuous reconciliation. Directory structure and command examples alone do not provide those behaviors.
