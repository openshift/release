# Metrics and Alerts

## User workload monitoring

This folder contains the manifests for user-workload-monitoring (UWM) based on [monitoring user-defined project on OSD cluster](https://docs.openshift.com/dedicated/osd_cluster_admin/osd_monitoring/osd-understanding-the-monitoring-stack.html) and managed by cluster-monitoring-operator (CMO).

The ServiceMonitors and the PodMonitors defines the scraping targets for Prometheus. The cluster console has the [UI](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/query-browser) to run queries against the metrics from those targets.

The active alerting sources and Makefile are in the
[core-ci mixins](../../core-ci/openshift-user-workload-monitoring/mixins/).
Run the following command from the repository root:

> make mixins

This generates core-ci alerting manifests in
[core-ci mixins/prometheus_out](../../core-ci/openshift-user-workload-monitoring/mixins/prometheus_out/).

The legacy app.ci `ci-alerts_prometheusrule.yaml` was trimmed to only the alerts
that cover app.ci-local workloads — `prow-pod-crashlooping`, `NonKubeContainerWaiting`,
`ciChatBotDown` and `releaseControllerDown` (plus the `github:identity_names`
recording rule). Every other alert was removed as a duplicate: core-ci's thanos-ruler
already evaluates those from ci-metrics, so the app.ci copy (evaluated by app.ci's UWM
Prometheus, which stamps a `namespace="ci"` label) only produced duplicate Slack
notifications. The four retained alerts stay because core-ci scopes its equivalents to
`clusterName="core-ci"` and therefore does not cover app.ci series; remove them once
app.ci's workloads are retired.

These [legacy app.ci outputs](mixins/prometheus_out/) retain their cluster-specific
namespace, labels and queries from the last pre-move source revision, `2c053f169aa^`;
they must not be replaced by copies of the core-ci outputs. To regenerate the
Alertmanager Template, extract that revision's app.ci mixin directory into a temporary
directory, copy the current
`_prometheus/{alertmanager_default_receivers,alertmanager,prometheus,ci_absent_alerts}.libsonnet`
files over the historical copies, and run its Makefile target
`alertmanager-user-workload-secret_template.yaml`
using the dashboards-validation image. Copy only that generated output back.

See the [retirement guidance](../../core-ci/ci-monitoring/README.md#retiring-alert-proxy-safely)
before removing proxy resources or credentials. Applying the Template does not
update the running Alertmanager configuration Secret.

[Here](../supplemental-ci-images/validation-images/dashboards/dashboards-validation.yaml) is the list of the required tools.

## Add an alert on Prow jobs

The metrics and the alerts defined here are for the TP team. CI users has [a more convenient way](https://docs.ci.openshift.org/docs/how-tos/notification/) if slack notifications are desired, e.g, on Prow job failures.

## Dashboards

Currently there is [no dashboard support in UWM](https://redhat-internal.slack.com/archives/C0VMT03S5/p1670228152637209?thread_ts=1670008515.321099&cid=C0VMT03S5).
Dashboards for ci-monitoring based on those metrics are deployed in [ci-grafana](../ci-grafana).
