# ghproxy Too Many Pending Alerts

This SOP covers `ghproxy-too-many-pending-alerts` on `app.ci`.

## What this alert means

This alert indicates the pending GitHub API request queue in `ghproxy` is elevated.

A single firing is usually not dangerous. Short spikes can happen during normal bursts.
The dangerous case is a trend: repeated firings or sustained queue growth over time.

## When to react

- One isolated firing: monitor, but do not treat as an outage by default.
- Multiple firings or sustained backlog: investigate immediately.

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
