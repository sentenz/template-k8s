# Runbook: Preserve Data, Recreate Kind Cluster, Restore

- [1. TL;DR](#1-tldr)
- [2. Generic CrashLoop execution workflow](#2-generic-crashloop-execution-workflow)
  - [2.1. Step 0 — Preflight and kubeconfig sanity](#21-step-0--preflight-and-kubeconfig-sanity)
  - [2.2. Step 1 — Inspect deployment state and recent logs](#22-step-1--inspect-deployment-state-and-recent-logs)
  - [2.3. Step 2 — Choose remediation path](#23-step-2--choose-remediation-path)
  - [2.4. Step 3A — Patch Kubernetes config and redeploy](#24-step-3a--patch-kubernetes-config-and-redeploy)
  - [2.5. Step 3B — Recreate cluster when node networking is broken](#25-step-3b--recreate-cluster-when-node-networking-is-broken)
  - [2.6. Step 4 — Verify rollout and service health](#26-step-4--verify-rollout-and-service-health)
- [3. Root cause (confirmed, incident 2026-10-28)](#3-root-cause-confirmed-incident-2026-10-28)
- [4. Data inventory](#4-data-inventory)
- [5. Prerequisites](#5-prerequisites)
- [6. Incident recovery procedure (2026-10-28)](#6-incident-recovery-procedure-2026-10-28)
  - [6.1. Phase 1 — Backup (cluster still up; postgres is healthy)](#61-phase-1--backup-cluster-still-up-postgres-is-healthy)
  - [6.2. Phase 2 — Recreate cluster (DESTRUCTIVE)](#62-phase-2--recreate-cluster-destructive)
  - [6.3. Phase 3 — Restore data](#63-phase-3--restore-data)
  - [6.4. Phase 4 — Verify](#64-phase-4--verify)
- [7. Actual execution results (2026-10-28)](#7-actual-execution-results-2026-10-28)
  - [7.1. Re-validation execution (2026-11-11)](#71-re-validation-execution-2026-11-11)
- [8. Relevant files / commands](#8-relevant-files--commands)
- [9. Decisions](#9-decisions)
- [10. Risks / notes](#10-risks--notes)

## 1. TL;DR

The `dependency-track-api-server` CrashLoopBackOff was caused by a kindnet CNI
route/IPAM desync on node `template-k8s-worker` (172.18.0.3) after a WSL2/host
restart. DNS timed out on that node, so the api-server could not resolve
`postgresql.postgresql.svc.cluster.local`. The desync does not self-heal
(CoreDNS + kindnet restarts did not fix it). The reliable fix is to recreate
the kind cluster. To avoid data loss, the PostgreSQL database was backed up
first, the cluster was recreated, and the data was restored.

## 2. Generic CrashLoop execution workflow

Use this flow first for any `CrashLoopBackOff` on `dependency-track-api-server`.
It matches the intended operating sequence:
inspect deployment + logs, apply the right fix path, and verify rollout.

### 2.1. Step 0 — Preflight and kubeconfig sanity

```bash
export KUBECONFIG=.local/kubeconfig/dev.yaml

# Fast sanity checks before troubleshooting:
test -s "$KUBECONFIG"
kubectl cluster-info
kubectl config current-context
```

If `kubectl` tries `localhost:8080` or returns `connection refused`, kubeconfig
is missing/not loaded; fix this before continuing.

If running commands in isolated shells/automation, prefer explicit kubeconfig
per command:

```bash
KUBECONFIG=.local/kubeconfig/dev.yaml kubectl get pods -A
```

### 2.2. Step 1 — Inspect deployment state and recent logs

```bash
kubectl get deploy,pods -n dependency-track -o wide
kubectl describe deploy/dependency-track-api-server -n dependency-track
kubectl logs deploy/dependency-track-api-server -n dependency-track --tail=200
kubectl logs deploy/dependency-track-api-server -n dependency-track --tail=200 --previous
```

Capture the first clear error signature (DNS, auth, connection refused, schema,
secret missing, probe failure, etc.). Do not patch blindly.

### 2.3. Step 2 — Choose remediation path

- **Path A (configuration/app issue):** Secret values, JDBC URL, chart values,
  env vars, probes, or resource limits are wrong.
- **Path B (cluster/node networking issue):** app config is correct, but DNS or
  service networking is broken on one/more nodes.

### 2.4. Step 3A — Patch Kubernetes config and redeploy

1. Edit the relevant declarative source (typically:
   `apps/dependency-track/overlays/<env>/values.yaml`,
   `infrastructure/services/postgresql/overlays/<env>/values.yaml`, or the
   environment kustomization files).
2. Redeploy from source of truth:

   ```bash
   echo "yes-dev" | make k8s-deploy K8S_ENV=dev
   ```

3. Watch rollout:

   ```bash
   kubectl rollout status deploy/dependency-track-api-server -n dependency-track --timeout=300s
   ```

### 2.5. Step 3B — Recreate cluster when node networking is broken

If diagnostics show node-level DNS/CNI desync (for example intermittent
`UnknownHostException` to in-cluster services from only some nodes), use this
document's incident recovery procedure in [Section 6](#6-incident-recovery-procedure-2026-10-28)
(backup → recreate cluster → redeploy → restore).

### 2.6. Step 4 — Verify rollout and service health

```bash
kubectl rollout status deploy/dependency-track-api-server -n dependency-track --timeout=300s
make k8s-observability
kubectl logs -n dependency-track -l app.kubernetes.io/component=api-server --tail=20
```

Success criteria:

- `dependency-track-api-server` is `Running 1/1` without increasing restarts.
- No `CrashLoopBackOff` in `make k8s-observability`.
- App logs show normal processing (not repeated bootstrap failures).

## 3. Root cause (confirmed, incident 2026-10-28)

- api-server log: `UnknownHostException: postgresql.postgresql.svc.cluster.local`
- DNS test pods: resolved fine on `template-k8s-worker2`, timed out on `template-k8s-worker`
- Node podCIDRs: worker=10.244.2.0/24, worker2=10.244.1.0/24
- Worker routes were inverted: `10.244.1.0/24 via 172.18.0.4` (worker2) and
  `10.244.2.0/24 via 172.18.0.3` (itself) → ClusterIP DNAT to a remote CoreDNS pod timed out
- Non-destructive reschedule was blocked: api-server PVC `dependency-track-storage`
  had PV node-affinity to `template-k8s-worker` (the broken node)
- Trigger: WSL2/host restart ~45 min before diagnosis (all nodes re-registered,
  leader re-elected, all system pods restarted)

## 4. Data inventory

| Volume          | PVC                        | Size | Pod            | Mount                      | Status at backup                                                 |
| --------------- | -------------------------- | ---- | -------------- | -------------------------- | ---------------------------------------------------------------- |
| PostgreSQL data | `data-postgresql-0`        | 8Gi  | `postgresql-0` | `/bitnami/postgresql/data` | **Populated** (31 projects, 611 components, 872K vulns, 8 users) |
| DT file storage | `dependency-track-storage` | 10Gi | api-server     | `/data`                    | **Empty** (4.0K, no files — api-server had been crashlooping)    |

Only the PostgreSQL database required backup and restore.

## 5. Prerequisites

```bash
# All kubectl commands require the cluster kubeconfig
export KUBECONFIG=.local/kubeconfig/dev.yaml
```

Key facts about the postgres pod (discovered during execution):

- Container name is **`postgresql`** (not `postgres`) — always use `-c postgresql`
- `pg_dump`/`pg_restore`/`psql` require `PGPASSWORD=dtrack` (no `.pgpass` in the container)
- Dependency-Track tables are **UPPERCASE** and must be double-quoted in SQL
  (e.g. `SELECT count(*) FROM "PROJECT"`, not `FROM project`)
- For automated scripts, avoid assuming exported env vars persist between
  commands; pass `KUBECONFIG=...` inline where needed.

## 6. Incident recovery procedure (2026-10-28)

### 6.1. Phase 1 — Backup (cluster still up; postgres is healthy)

1. Create backup dir:

   ```bash
   BK="logs/backup/$(date -u +%Y%m%dT%H%M%SZ)"
   mkdir -p "$BK"
   ```

2. Dump the DB from the running postgres pod:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- \
     env PGPASSWORD=dtrack pg_dump -U dtrack -d dtrack -Fc -f /tmp/dtrack.dump
   ```

   Verify the dump was created:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- ls -la /tmp/dtrack.dump
   ```

3. Copy dump to host:

   ```bash
   kubectl cp postgresql/postgresql-0:/tmp/dtrack.dump "$BK/dtrack.dump" -c postgresql
   ```

4. Verify the dump on the host (header should be `PGDMP`):

   ```bash
   head -c 5 "$BK/dtrack.dump"   # → PGDMP
   ls -lh "$BK/dtrack.dump"
   ```

5. Clean up the in-pod dump:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- rm -f /tmp/dtrack.dump
   ```

6. *(Optional)* Check file storage for data. If the api-server has been
   crashlooping, `/data` is likely empty and no file-storage backup is needed:

   ```bash
   # Quick check via a helper pod
   kubectl run -n dependency-track fs-check --rm -i --restart=Never \
     --image=busybox:1.36 --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"dependency-track-storage"}}],"containers":[{"name":"c","image":"busybox:1.36","command":["sh","-c","du -sh /data && ls -la /data"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
   ```

### 6.2. Phase 2 — Recreate cluster (DESTRUCTIVE)

> [!WARNING]
> This wipes all nodes, PVCs, and data. Confirm Phase 1 backup is verified first.

1. Delete the cluster:

   ```bash
   make k8s-teardown K8S_ENV=dev
   ```

2. Create a fresh cluster:

   ```bash
   make k8s-bootstrap K8S_ENV=dev
   ```

3. Redeploy all apps (postgres, dependency-track, traefik):

   ```bash
   echo "yes-dev" | make k8s-deploy K8S_ENV=dev
   ```

   The `k8s-confirm` target reads from stdin, so pipe the confirmation.

### 6.3. Phase 3 — Restore data

1. Wait for postgres to be ready:

   ```bash
   kubectl rollout status statefulset/postgresql -n postgresql --timeout=300s
   ```

2. Verify DNS works on all nodes (confirms the CNI desync is resolved):

   ```bash
   for n in template-k8s-control-plane template-k8s-worker template-k8s-worker2; do
     kubectl run -n dependency-track dns-$n --restart=Never --image=busybox:1.36 \
       --overrides="{\"spec\":{\"nodeName\":\"$n\"}}" \
       -- nslookup postgresql.postgresql.svc.cluster.local >/dev/null 2>&1
     sleep 5
     kubectl logs -n dependency-track dns-$n 2>&1 | grep -c "10.96"
     kubectl delete pod -n dependency-track dns-$n --wait=false
   done
   ```

   Each node should return a non-zero count (resolved IP).

3. Copy the dump into the new postgres pod:

   ```bash
   kubectl cp "$BK/dtrack.dump" postgresql/postgresql-0:/tmp/dtrack.dump -c postgresql
   ```

4. Restore the database:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- sh -ec '
     rc=0
     env PGPASSWORD=dtrack pg_restore -U dtrack -d dtrack \
       --clean --if-exists /tmp/dtrack.dump > /tmp/restore.log 2>&1 || rc=$?
     echo "restore_exit=$rc"
     grep -iE "error|fatal" /tmp/restore.log | \
       grep -viE "does not exist, skipping|newer version|archive was created with" || true
   '
   ```

5. *(Optional but recommended)* Integrity check for known workflow-history
   orphan rows after restore:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- \
     env PGPASSWORD=dtrack psql -U dtrack -d dtrack -tAc \
     "SELECT count(*) FROM dex_workflow_history h
      LEFT JOIN dex_workflow_run r ON h.workflow_run_id=r.id
      WHERE r.id IS NULL;"
   ```

   If this count is non-zero, `pg_restore` may report a foreign-key warning for
   `dex_workflow_history_workflow_run_fk`; this warning is non-blocking for
   service startup but should be tracked for DB hygiene.

6. Verify restored data:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- \
     env PGPASSWORD=dtrack psql -U dtrack -d dtrack -tAc \
     "SELECT 'PROJECT', count(*) FROM \"PROJECT\"
      UNION ALL SELECT 'COMPONENT', count(*) FROM \"COMPONENT\"
      UNION ALL SELECT 'VULNERABILITY', count(*) FROM \"VULNERABILITY\"
      UNION ALL SELECT 'USER', count(*) FROM \"USER\";"
   ```

7. Clean up the in-pod dump:

   ```bash
   kubectl exec -n postgresql postgresql-0 -c postgresql -- rm -f /tmp/dtrack.dump /tmp/restore.log
   ```

8. The api-server will self-heal once DNS is working — no manual restart needed.
   If it is still in CrashLoopBackOff from before the cluster recreation, the
   deployment controller will create a new pod automatically. Verify:

   ```bash
   kubectl rollout status deploy/dependency-track-api-server -n dependency-track --timeout=300s
   ```

### 6.4. Phase 4 — Verify

1. Full cluster health:

   ```bash
   make k8s-observability
   ```

   All pods should be `Running 1/1` with no `CrashLoopBackOff`.

2. Confirm api-server is actively processing (not just "up"):

   ```bash
   kubectl logs -n dependency-track -l app.kubernetes.io/component=api-server --tail=20
   ```

   Look for `AnalyzeProjectWorkflow` / `Project analysis completed` entries —
   these confirm the api-server is reading from the restored database.

3. *(Optional)* Open <https://dependency-track.localhost> and confirm projects
   and data are visible in the UI.

## 7. Actual execution results (2026-10-28)

| Phase         | Result                                                                                             |
| ------------- | -------------------------------------------------------------------------------------------------- |
| Backup        | `logs/backup/20261028T080340Z/dtrack.dump` — 295 MB, valid `PGDMP` header                          |
| File storage  | Confirmed empty (4.0K) — no backup needed                                                          |
| Teardown      | 3 nodes deleted cleanly                                                                            |
| Bootstrap     | Cluster ready in 9s (node image cached)                                                            |
| Deploy        | All resources created (namespaces, secrets, PVCs, deployments, statefulset, ingress)               |
| DNS check     | All 3 nodes resolved `postgresql.postgresql.svc.cluster.local`                                     |
| pg_restore    | exit=0, 0 error lines                                                                              |
| Data verified | 157 tables; PROJECT=31, COMPONENT=611, VULNERABILITY=872294, USER=8                                |
| api-server    | Running 1/1 on `template-k8s-worker` (previously broken node), actively running analysis workflows |
| Observability | All pods Running 1/1, no CrashLoopBackOff                                                          |

### 7.1. Re-validation execution (2026-11-11)

| Phase            | Result                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------ |
| Symptom          | `dependency-track-api-server` in `CrashLoopBackOff`; log showed `UnknownHostException: postgresql...`       |
| Backup           | `logs/backup/20261111T125626Z/dtrack.dump` — 288 MB, valid `PGDMP` header                                  |
| Recreate+deploy  | `k8s-teardown` + `k8s-bootstrap` + `k8s-deploy` completed successfully                                      |
| Restore          | Completed with one FK warning for `dex_workflow_history_workflow_run_fk` (orphan history rows present)     |
| Data verified    | PROJECT=32, COMPONENT=636, VULNERABILITY=885561, USER=17                                                     |
| Runtime verified | Rollout successful; logs showed `AnalyzeProjectWorkflow` / `Project analysis completed`; no CrashLoopBackOff |

## 8. Relevant files / commands

- `Makefile` — `k8s-teardown`, `k8s-bootstrap`, `k8s-deploy`, `k8s-observability`
  (kubeconfig at `.local/kubeconfig/dev.yaml`; all kubectl calls need `KUBECONFIG` set)
- `clusters/dev/kustomization.yaml` — composition (controllers, configs, apps)
- `infrastructure/services/postgresql/overlays/dev/` — postgres chart 18.12.4, ns `postgresql`
- `apps/dependency-track/overlays/dev/` — dependency-track chart 2.8.0, ns `dependency-track`
- `vendor/helm/postgresql-18.12.4/.../primary/statefulset.yaml` — volumeClaimTemplate `data`
- `vendor/helm/dependency-track-2.8.0/.../file-storage/pvc.yaml` — PVC `dependency-track-storage`

## 9. Decisions

- **Logical `pg_dump`/`pg_restore`** for the DB (robust, version-tolerant) rather than
  raw data-dir swap (fragile with a StatefulSet).
- **Skip file-storage backup** when `/data` is empty (confirmed via helper pod).
- **Backups stored under `logs/backup/<timestamp>/`** on the host (outside the cluster).
- **Scope: dev cluster only.** stage/prod untouched.
- **No manual api-server restart** — the deployment controller handles pod recreation
  after cluster recreation; the api-server self-heals once DNS is functional.

## 10. Risks / notes

- `k8s-deploy` requires interactive `yes-dev` confirmation (pipe via `echo "yes-dev" |`).
- If `pg_dump` as `dtrack` fails on permissions, retry with `-U postgres` and
  `PGPASSWORD=longpassword`.
- `pg_restore` with `--clean --if-exists` is idempotent — safe to re-run if the
  first attempt partially fails.
- `pg_restore` may report one warning for
  `dex_workflow_history_workflow_run_fk` when legacy orphan rows exist; this
  did not block startup in the 2026-11-11 run, but should be tracked as a data
  integrity cleanup task.
- After restore, the api-server may show a few restarts during initial startup
  (schema migration checks) before stabilizing. This is normal.
- The backup file at `logs/backup/20261028T080340Z/dtrack.dump` can be deleted
  once the restored data is confirmed in the UI.
