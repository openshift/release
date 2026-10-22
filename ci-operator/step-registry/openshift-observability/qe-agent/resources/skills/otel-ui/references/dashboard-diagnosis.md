# OpenTelemetry Console UI — Failure Signals and Known Dashboard Behaviour

### Failure text → cause

| Signal | Check | Likely classification |
|---|---|---|
| Login: timeout on `#inputUsername` or `[data-test="username"]`; `No kubeadmin password file` | console and authentication operators, console pods, `curl -sk -o /dev/null -w '%{http_code}' https://<console host>/` | login page changed: `TEST_ISSUE`; console or OAuth down: `PRODUCT_BUG`; missing password file: `JOB_CONFIG` |
| `ConfigMap openshift-config-managed/opentelemetry-collector not found` | `OPENSHIFT_CREATE_DASHBOARD` in the CSV, operator restarts, operator logs | flag unset in the bundle: `JOB_CONFIG`; flag set, operator running, ConfigMap missing: `PRODUCT_BUG`; operator restarted meanwhile: see `CLUSTER_INSTABILITY` below |
| ConfigMap label or `title` assertion | the ConfigMap label and `.title` in `otel.json` | intended rename: `TEST_ISSUE`; unintended: `PRODUCT_BUG` |
| Observe, Dashboards, `dashboard-dropdown` or picker option not found | ConfigMap label, `monitoring-plugin` pods, console plugins (`oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'`) | console UI change: `TEST_ISSUE`; plugin not running: `PRODUCT_BUG` |
| row not visible, `toHaveCount(3)` | rows and panels in `otel.json` against the spec | dashboard changed on purpose: `TEST_ISSUE`; broken JSON: `PRODUCT_BUG` |
| `No datapoints found.`, legend missing, `toPass` timeout on a panel; or Chainsaw `Timed out after … waiting for series` | Step 3 query counts | series absent: data path (user workload monitoring pods, ServiceMonitor `*-monitoring-collector`, `enableMetrics`, telemetrygen logs); collector metric names no longer match the dashboard queries (for example a `_total` suffix): `PRODUCT_BUG`. Series present: compare `legendFormat` in `otel.json` with `PANELS`: changed `TEST_ISSUE`, same `PRODUCT_BUG` (console rendering) |
| `metric exporter` dropdown missing `otlp/unreachable` | `otelcol_exporter_send_failed_metric_points` in the counts | the always-failing exporter no longer fails: `TEST_ISSUE` (fixture) |
| collector instance or namespace filter | Service names `<cr>-collector-monitoring` | Service renamed by the operator: `PRODUCT_BUG`, else `TEST_ISSUE` |
| `ImagePullBackOff` of `telemetrygen` or the collector | pod events, registry reachability | `JOB_CONFIG` |

### Known dashboard behaviour (verified on OCP 4.22, operator 0.158)

- **Metrics Exported vs Failed / second** is empty until `otelcol_exporter_send_failed_metric_points` exists (the `metric exporter` variable is built from it, so the console sends `undefined` queries). The fixture avoids it with the failing `otlp/unreachable` exporter. Do not file this again as new unless that series exists and the panel is still empty.
- The `dropped` series of both Processor panels cannot exist (the memory limiter has no dropped metric); `refused` series may be absent (they can be missing until a refusal happens). The specs do not assert them.
- The dashboard is offered only for All Projects, panels render lazily, and a first-time user gets a welcome dialog: the spec handles all three.
