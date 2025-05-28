# CI-Grafana

This folder contains the manifests for Grafana managed by [grafana-operator](https://github.com/grafana-operator/grafana-operator).

## Dashboards

The dashboards for Grafana are generated from [mixins](../openshift-user-workload-monitoring/mixins) with the command:

> make -C clusters/app.ci/openshift-user-workload-monitoring/mixins all

The generated dashboards are stored in [mixins/grafana_dashboards_out](../openshift-user-workload-monitoring/mixins/grafana_dashboards_out).
The `jsonnet` objects are there because it is easy for validation in CI if all the mixins generated manifests stay together.

## Staging

We do not have a staging grafana instance for developing dashboards any more.
With grafana-operator, we could apply the generated dashboard to preview the dashboard with the production instance.

The current grafana-operator, 4.8.0 as this readme is written, manages only one grafana instance.
We have to [deploy everything all over again](https://kubernetes.slack.com/archives/C019A1KTYKC/p1670534010925499) for staging instance into another namespace
which will be fixed when Version 5+ is available.
We can start up the staging instance then if needed.
 