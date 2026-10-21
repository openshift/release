# Blackbox Probe Service Failing

## Alert binding

| Field | Value |
|-------|-------|
| **Alerts** | `ProbeFailing` (≥1m), `ProbeFailing-Lenient` (≥5m) |
| **Cluster** | `app.ci` |
| **Rules** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml) — `blackbox` group |
| **Severity** | `critical` |
| **Prober** | Deployment **`blackbox-prober`** in namespace **`ci`** ([`blackbox_prober.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/blackbox_prober.yaml)); Prometheus probes call **`blackbox-prober.ci.svc`**. |

This alert means the blackbox exporter cannot successfully scrape one of the targets listed in [`blackbox_probe.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/blackbox_probe.yaml). The failing HTTP/HTTPS URL is in **`{{ $labels.instance }}`** on the alert.

## Symptom

- **`ProbeFailing`**: failing ≥ **1 minute**.
- **`ProbeFailing-Lenient`**: failing ≥ **5 minutes**.

## Diagnose

### 1) Confirm prober pods are healthy

```bash
CTX=app.ci

oc --context "$CTX" get pods -n ci -l app=blackbox-prober -o wide
oc --context "$CTX" describe pod -n ci -l app=blackbox-prober | grep -A20 '^Conditions:'
```

If pods are **CrashLoop** / **Pending**, fix prober first—otherwise downstream targets all fail.

### 2) Read blackbox exporter logs (target errors, TLS, timeouts)

```bash
oc --context "$CTX" logs -n ci -l app=blackbox-prober --tail=200 --all-containers=true
```

Look for **`statusCode`**, **`tls`**, **`timeout`**, **`connection refused`** matching the **`instance`** host.

### 3) Test connectivity from inside the cluster (same network path as probes)

The **`blackbox-exporter`** image is minimal—**`oc exec` often has no shell**. Prefer a short-lived debug pod with **`curl`**:

```bash
TARGET='https://example.apps.ci.l2s4.p1.openshiftapps.com/healthz'

oc --context "$CTX" run bb-debug-"$(date +%s)" -n ci --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  -- curl -vk --max-time 20 "$TARGET"
```

Delete manually if **`--rm`** did not clean up (policy permitting):

```bash
oc --context "$CTX" delete pod -n ci bb-debug-<suffix>
```

**Interpretation:**

- **Connection refused / no route**: target Service endpoints down, Route missing, or NetworkPolicy—inspect target namespace.
- **HTTP 5xx**: application degraded—engage service owners.
- **TLS verify errors**: cert mismatch or expired cert—check Route **`spec.tls`** / cert secrets; correlate with alert **`SSLCertExpiringSoon`** on the same target ([`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml)).

### 4) Map URL → OpenShift Route / Service (when host is `*.apps.ci…`)

```bash
HOST=$(echo "$TARGET" | sed -e 's|https\?://||' -e 's|/.*||')
oc --context "$CTX" get routes --all-namespaces -o json \
  | jq -r --arg h "$HOST" '.items[] | select(.spec.host==$h) | "\(.metadata.namespace)/\(.metadata.name)"'
```

Then inspect backing Service / Deployment:

```bash
NS=<route-namespace>
ROUTE=<route-name>

oc --context "$CTX" get route -n "$NS" "$ROUTE" -o yaml
oc --context "$CTX" get endpoints -n "$NS" "$(oc --context "$CTX" get route -n "$NS" "$ROUTE" -o jsonpath='{.spec.to.name}')" -o yaml
```

### 5) Compare external vs in-cluster

From your workstation (if permitted):

```bash
curl -vk --max-time 15 "$TARGET"
```

- Works **externally** but fails **from prober**: cluster egress / DNS / split-horizon issue.
- Fails **both**: likely real outage or global routing problem.

## Fix

1. **Restore the failing component** (rollout pod/Deployment behind Route; fix TLS secret; repair DNS).
2. **Tune obsolete alerts**: if target intentionally removed, edit **`blackbox_probe.yaml`** and remove/update module/target—open PR on **`openshift/release`**.
3. **Tune thresholds**: only after confirming benign blips—prefer fixing root cause.

## Verify

- Prometheus **`probe_success{job=~"blackbox|blackbox-lenient", instance="<url>"} == 1`** for sustained window.
- Alert clears in Alertmanager / Slack.

## Escalation

If multiple unrelated targets fail simultaneously, suspect **cluster networking / ingress** on **`app.ci`**—page **`@dptp-triage`** with prober logs + output from the **`curlimages/curl`** debug pod command above.
