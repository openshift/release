# ghproxy Too Many Pending Alerts

## Alert binding

| Field | Value |
|-------|-------|
| **Alert** | `ghproxy-too-many-pending-alerts` |
| **Cluster** | `app.ci` |
| **Rules** | [`ci-alerts_prometheusrule.yaml`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml); source [`ghproxy_alerts.libsonnet`](../../clusters/app.ci/openshift-user-workload-monitoring/mixins/_prometheus/ghproxy_alerts.libsonnet) |
| **Severity** | `critical` |

This SOP covers `ghproxy-too-many-pending-alerts` on `app.ci`.

## What this alert means

This alert indicates the pending GitHub API request queue in `ghproxy` is elevated.

A single firing is usually not dangerous. Short spikes can happen during normal bursts.
The dangerous case is a trend: repeated firings or sustained queue growth over time.

## When to react

- One isolated firing: monitor, but do not treat as an outage by default.
- Multiple firings or sustained backlog: investigate immediately.

## Diagnose on-cluster (`app.ci`)

Deployment **`ghproxy`** lives in namespace **`ci`** ([`ghproxy.yaml`](../../clusters/app.ci/prow/03_deployment/ghproxy.yaml), labels **`app=prow`**, **`component=ghproxy`**).

### 1) Pod health

```bash
CTX=app.ci

oc --context "$CTX" get pods -n ci -l app=prow,component=ghproxy -o wide
oc --context "$CTX" describe pod -n ci -l app=prow,component=ghproxy | grep -A12 '^Conditions:'
```

### 2) Recent ghproxy logs (errors, cache, upstream GitHub)

```bash
oc --context "$CTX" logs -n ci deploy/ghproxy --tail=300 \
  | grep -iE 'error|429|403|timeout|backoff' || true
```

Interpret:

- **429 / 403 spikes**: GitHub rate limit / token permission—correlate with token metrics below.
- **Dial / TLS errors**: egress or GitHub incident.

### 3) Metrics port (inline sanity)

Service **`ghproxy`** exposes **`9090`** named **`metrics`**—scrape targets should be **`UP`** in monitoring; if local pod healthy but alert persists, verify Service endpoints:

```bash
oc --context "$CTX" get endpoints -n ci ghproxy -o yaml
```

### 4) In-flight ConfigMap / deployment drift

```bash
oc --context "$CTX" get deploy/ghproxy -n ci -o yaml | grep -A3 ' image:'
```

Compare with Git [`ghproxy.yaml`](../../clusters/app.ci/prow/03_deployment/ghproxy.yaml) if image unexpectedly old.

## Investigation queries (Prometheus on app.ci)

### 1) Plugin handling latency (median)
Use this to identify plugins getting slower:

```promql
histogram_quantile(0.5, sum(rate(prow_plugin_handle_duration_seconds_bucket{took_action="true"}[30m])) by (le, plugin))
```

### 2) Plugin handling latency (p95 / worst-case trend)
Use this to detect long-tail plugin delays:

```promql
histogram_quantile(0.95, sum(rate(prow_plugin_handle_duration_seconds_bucket{took_action="true"}[30m])) by (le, plugin))
```

### 3) `openshift-merge-bot` 403 ratio (Tide-related pressure)
High 403 ratio can indicate token pressure / throttling:

```promql
sum(rate(github_request_duration_count{status=~"403", token_hash="openshift-merge-bot - openshift"}[60m])) / sum(rate(github_request_duration_count{token_hash="openshift-merge-bot - openshift"}[60m]))
```

### 4) `openshift-ci` 403 ratio
High 403 ratio can indicate token pressure / throttling:

```promql
sum(rate(github_request_duration_count{status=~"403", token_hash="openshift-ci - openshift"}[60m])) / sum(rate(github_request_duration_count{token_hash="openshift-ci - openshift"}[60m]))
```

### 5) Share of requests completing under 10s by API and request type
This helps locate slow APIs/request paths behind queue buildup:

```promql
sum(rate(github_request_wait_duration_seconds_bucket{le="10", token_hash="openshift-ci - openshift"}[60m])) by (api, request_type) / sum(rate(github_request_wait_duration_seconds_count{token_hash="openshift-ci - openshift"}[60m])) by (api, request_type)
```

## Follow-up actions

1. Confirm whether the queue backlog is persistent (trend) rather than a short spike.
2. Identify which plugin(s), API(s), or request type(s) are contributing most to delay.
3. Check the two 403 ratio queries:
   - if high, treat this primarily as rate-limit/token pressure
   - if low, focus on plugin/API latency and queue throughput
4. If sustained pressure is confirmed, and there is no significant 403 pressure (secondary rate-limit signal), tune `ghproxy` timing/throttling settings in:
   - [`clusters/app.ci/prow/03_deployment/ghproxy.yaml`](https://github.com/openshift/release/blob/main/clusters/app.ci/prow/03_deployment/ghproxy.yaml)
5. After changes, monitor queue depth and request latency/403 ratios to confirm recovery.
