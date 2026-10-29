# OpenShift Priv Image Building Jobs

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `openshift-priv-image-building-jobs-failing` |
| **Cluster** | `app.ci` |
| **Rules** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) — group `openshift-priv-image-building-jobs-failing` |
| **Severity** | `critical` |

This alert fires when an `openshift-priv` image-building job has a poor 12h success ratio while its corresponding public `openshift` image-building job remains healthy.
The images built from these jobs are often not used, but they do need to be readily available when needed for a CVE fix.
The alert compares paired jobs by suffix:
- Priv: `branch-ci-openshift-priv-<suffix>-images`
- Public: `branch-ci-openshift-<suffix>-images`
This avoids alerting on inherited failures where the public job failed first and the priv job failed as a downstream consequence.

## Useful Links
- [Recent executions on Deck Internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=*-images)
- [Priv image jobs on Deck Internal](https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/?job=branch-ci-openshift-priv-.*-images)
- [Public image jobs on Deck](https://prow.ci.openshift.org/?job=branch-ci-openshift-.*-images)
- [Prometheus Query Browser](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser)

## Triage

### Symptom
Alert message contains:
- The specific failing priv job: `branch-ci-openshift-priv-{{ $labels.job_tail }}`
- The corresponding public job: `branch-ci-openshift-{{ $labels.job_tail }}`
- Direct links to both jobs.

### Resolution
1. Open the linked priv job history and identify the dominant failure mode.
2. Open the linked public counterpart and confirm it is healthy (it should be, by rule design).
3. If priv-only failures persist, reach out to repo owners and/or CI maintainers with both links and failure signatures.
4. If the public job is also failing but this alert fired, treat that as a rule/parsing edge case and open a release-repo PR to refine matching.

## Diagnose with `oc` (`app.ci`)

Set names from the Slack alert (**`job_tail`** suffix):

```bash
CTX=app.ci
# TAIL = Prometheus label job_tail (regex capture after branch-ci-openshift-priv-). Example: hypershift-main-images — not openshift-hypershift-main-images or branch-ci-openshift-${TAIL} duplicates openshift.
TAIL=<job_tail-from-alert>
PRIV_JOB="branch-ci-openshift-priv-${TAIL}"
PUB_JOB="branch-ci-openshift-${TAIL}"
```

### 1) Latest ProwJob objects

```bash
oc --context "$CTX" get prowjobs.prow.k8s.io -n ci \
  --sort-by=.metadata.creationTimestamp \
  | grep -E "$PRIV_JOB|$PUB_JOB" | tail -20
```

Capture **`NAME`** for one failing **`PRIV_JOB`** run.

### 2) Compare states side-by-side

```bash
PRIV_PJ=<priv-prowjob-name>
PUB_PJ=<public-prowjob-name>

oc --context "$CTX" get prowjob.prow.k8s.io -n ci "$PRIV_PJ" \
  -o custom-columns='JOB:.spec.job,STATE:.status.state,START:.status.startTime,URL:.status.url'

oc --context "$CTX" get prowjob.prow.k8s.io -n ci "$PUB_PJ" \
  -o custom-columns='JOB:.spec.job,STATE:.status.state,START:.status.startTime,URL:.status.url'
```

### 3) ci-operator logs for the failing priv build

```bash
BUILD_ID=<from priv Deck URL>

oc --context "$CTX" get pods --all-namespaces \
  -l prow.k8s.io/build-id="$BUILD_ID" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'

TEST_NS=<ci-op-*>

OP_POD=$(oc --context "$CTX" get pods -n "$TEST_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^ci-operator-' | head -1)

oc --context "$CTX" logs -n "$TEST_NS" "$OP_POD" -c test --tail=600 \
  | grep -iE 'level=error|step_failed|Reason:' | tail -40
```

### 4) Policy reminder

**`openshift-priv`** builds often need extra credentials—failures may be **RBAC / secret mount** on private Git sidecars; compare with healthy public job pod specs only via **`oc describe`** (avoid dumping Secret data):

```bash
oc --context "$CTX" describe prowjob.prow.k8s.io -n ci "$PRIV_PJ" | tail -40
```
