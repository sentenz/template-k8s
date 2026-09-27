# Reconciliation contract

`clusters/<environment>/` is the authoritative composition for one concrete
cluster. A delivery system should render and reconcile its child roots in this
order, waiting for readiness between stages:

1. `controllers/` — operators, CRDs, admission webhooks, and ingress.
2. `configs/` — platform services, namespaces, and cluster configuration.
3. `apps/` — application namespaces, workload-specific Secrets, and application workloads.

The aggregate `clusters/<environment>/kustomization.yaml` is the review and
rendering entry point. It must not also be reconciled as a second owner of the
same objects when the child roots are reconciled independently.

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

With Python 3, PyYAML, Helm, Kustomize, and the development TLS fixtures
available, run `python3 -m unittest discover -s tests -p 'test_*.py' -v`.
The checks cover Make environment selection and atomic rendering, then compare
each aggregate render with its independently rendered children and verify
namespace availability and unique resource ownership across stages.
