# Reconciliation contract

`clusters/<environment>/` is the authoritative composition for one concrete
cluster. A delivery system should render and reconcile its child roots in this
order, waiting for readiness between stages:

1. `controllers/` — operators, CRDs, admission webhooks, and ingress.
2. `configs/` — infrastructure services, namespaces, and cluster configuration.
3. `apps/` — application namespaces, workload-specific Secrets, and application workloads.

The aggregate `clusters/<environment>/kustomization.yaml` is the review and
rendering entry point. It must not also be reconciled as a second owner of the
same objects when the child roots are reconciled independently.

When migrating an existing aggregate reconciliation to child roots, suspend the
old reconciliation and disable its pruning and deletion of managed resources
before changing paths or removing its inventory. Use the delivery system's
orphan/adoption procedure to transfer ownership without deleting live objects.
Verify that every resource has exactly one child owner before enabling pruning
under the lifecycle policy below.

Each child root includes the cluster-local `labels/` component so independent
builds and the aggregate render carry identical resource and pod-template labels
without changing selectors. The development TLS Secret belongs to `apps/`,
alongside the namespace that it requires. Apply namespaces before namespaced
resources within each stage; wait for workloads only after the stage is applied.
Stage and production require externally provisioned database and application
Secrets before their respective workload readiness gates can pass.

The Make `k8s-deploy` target remains an aggregate apply convenience and does not
implement these inter-stage readiness gates or inventory-based pruning.

The reconciler must pin the Git revision, Kustomize and Helm versions, chart
inputs, and target cluster. It must report render, apply, readiness, and prune
failures and retain the applied revision with rollout status. Pruning must use
an explicit inventory; namespaces, CRDs, and persistent data require deliberate
lifecycle policy and must not be removed by a blanket cluster delete.

Rendering is not deployment. Changes are promoted by updating the appropriate
environment overlay and merging the reviewed Git change. Emergency manual
application must use an explicit Kubernetes context and be followed by the
corresponding Git change to restore convergence.

Roll back by reverting the environment configuration to a known-good Git
revision and reconciling the same child roots in dependency order. Confirm
application and database compatibility first: reverting manifests does not
reverse database migrations or restore persistent data.

## Validation

Prepare the [development TLS fixtures](../apps/dependency-track/README.md#2-development)
and make Docker available. From the repository root, render all environments
and their child roots with the Make target's pinned tool image:

```bash
set -euo pipefail

for environment in dev stage prod; do
  make k8s-render K8S_ENV="$environment"
  for root in controllers configs apps; do
    make k8s-render \
      K8S_ENV="$environment" \
      K8S_CLUSTER_PATH="clusters/$environment/$root" \
      K8S_RENDER_FILE="render/kustomize/$environment/$root.yaml"
  done
done
```

These commands check renderability. During review, compare the aggregate with
the union of its children by API group, kind, namespace, and name, ignoring
document order. Resource content, labels, and selectors must match; each object
must have one owner, and each required namespace must belong to the same or an
earlier stage.

The Kind workflow validates the development aggregate with a live deployment
and ingress checks. It does not exercise independent child reconciliation,
stage/production Secret provisioning, or inventory-based pruning.
