# Reconciliation contract

`clusters/<environment>/` is the authoritative composition for one concrete
cluster. A delivery system should render and reconcile its child roots in this
order, waiting for readiness between stages:

1. `controllers/` — operators, CRDs, admission webhooks, and ingress.
2. `configs/` — platform services, namespaces, and cluster configuration.
3. `apps/` — application workloads.

The aggregate `clusters/<environment>/kustomization.yaml` is the review and
rendering entry point. It must not also be reconciled as a second owner of the
same objects when the child roots are reconciled independently.

The reconciler must pin the Git revision, Kustomize and Helm versions, chart
inputs, and target cluster. It must report render, apply, readiness, and prune
failures and retain the applied revision with rollout status. Pruning must use
an explicit inventory; namespaces, CRDs, and persistent data require deliberate
lifecycle policy and must not be removed by a blanket cluster delete.

Rendering is not deployment. Changes are promoted by updating the appropriate
environment overlay and merging the reviewed Git change. Emergency manual
application must use an explicit Kubernetes context and be followed by the
corresponding Git change to restore convergence.
