# Argo CD Application OutOfSync

**Alerts:** `ArgoCDApplicationOutOfSync` — **Slack:** `#ops-testplatform`. **Rules:** [`openshift-gitops_argocd-prometheusrule.yaml`](../../clusters/core-ci/argocd/openshift-gitops_argocd-prometheusrule.yaml) (core-ci, `openshift-gitops`). **Severity:** `warning`. **Routing:** Alertmanager groups by `alertname` (`group_interval` 4h); still-firing refire every **24h**.

Zero tolerance: any Argo CD Application managed by core-ci GitOps that stays `OutOfSync` for ~1m fires a per-Application alert (labels identify Application + destination); Slack clubs them into one message.

## Labels from Slack / Prometheus

| Label | Meaning |
|-------|---------|
| **`name`** | Argo CD Application name (usually a directory basename under `clusters/`) |
| **`project`** | Argo CD AppProject (`core-ci`, `app-ci`, `build-clusters`, …) |
| **`dest_server`** | Destination cluster API URL the Application syncs to |
| **`cluster`** | Static `core-ci` (GitOps control plane where the rule is evaluated) |

Related aggregate (count only, no app name): `ArgoCDApplicationNotSyncedOrHealthy`.

## Diagnose

### 1) Confirm which Application and destination

Replace `APPNAME` with the Application `name` from the alert (e.g. `argocd`, `hive-pools`):

```bash
oc --context core-ci -n openshift-gitops get application APPNAME -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEST_NAME:.spec.destination.name,DEST_SERVER:.spec.destination.server'
```

UI: [openshift-gitops on core-ci](https://openshift-gitops-server-openshift-gitops.apps.core.ci.devcluster.openshift.com) → Applications → filter by Application name.

### 2) Inspect the diff

```bash
oc --context core-ci -n openshift-gitops get application APPNAME -o json | jq '.status.resources | map(select(.status=="OutOfSync" or .health.status!="Healthy")) | .[] | {kind,name,namespace,status,health}'
```

Or in the Argo CD UI: open the Application → **App Diff**.

### 3) Common causes and remediations

| Cause | What to do |
|-------|------------|
| Recent merge not synced yet | Wait for auto-sync, or `oc --context core-ci -n openshift-gitops annotate application APPNAME argocd.argoproj.io/refresh=hard --overwrite` then sync |
| Manual / live drift on the destination cluster | Revert live change via Git, or sync (self-heal is off for most apps) |
| Controller-owned fields (IST, image triggers, Namespace PSA) | Prefer `ignoreDifferences` on the ApplicationSet (see DPTP-5387); do not patch live to “green” |
| Failed sync (`ArgoCDSyncFailures`) | Check Application conditions / operation message; fix RBAC, CRD, or invalid manifest |
| Missing `ci.openshift.io/gitops-managed=true` label | Objects outside `resource.selectors` look drifted or are ignored; add the label in Git |

Do **not** leave one-off `oc apply` / console edits on managed clusters as the fix—commit the intended state to `openshift/release`.

## Validate the alert (controlled OutOfSync)

1. Pick a low-risk Application from `appset-cluster-core-ci` (`selfHeal: false`) and note it is Synced.
2. Introduce a harmless, reversible live drift on one managed object; wait at least **1m** (`for:`) plus one Thanos evaluation interval.
3. Confirm `ArgoCDApplicationOutOfSync` fires with the Application `name` and stays firing while OutOfSync remains.
4. Restore sync via Git; confirm the alert clears once the Application is Synced again. Do not leave the cluster OutOfSync.

## Configuration

- **PrometheusRule:** `clusters/core-ci/argocd/openshift-gitops_argocd-prometheusrule.yaml`
- **Selected by:** Thanos Ruler `ci-metrics` via `app.kubernetes.io/managed-by: thanos-operator`
- **Alertmanager:** route `ArgoCDApplicationOutOfSync` → `slack-ops-testplatform` (`#ops-testplatform`), `group_by: [alertname]`, `group_interval` `4h`, `repeat_interval` `24h` (see mixins `_prometheus/alertmanager_*.libsonnet`)
