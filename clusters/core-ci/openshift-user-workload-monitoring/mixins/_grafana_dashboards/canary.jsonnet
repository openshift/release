local config =  import '../config.libsonnet';
local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 350
        },
    };

local dashboardConfig = {
        uid: config._config.grafanaDashboardIDs['canary.json'],
    };

local jobRate(regex, state) = std.format('sum(rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"canary-openshift-ocp-installer-e2e-%s",job_name!~"rehearse.*",state=~"%s"}[48h]))', [regex, state]);
local targetFor(regex, format) = prometheus.target(
    std.format("%s/%s", [jobRate(regex, "success"), jobRate(regex, "success|failure")]),
    legendFormat=format,
);

dashboard.new(
        'Release-Informing Jobs Dashboard',
        time_from='now-1w',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'Canary Release Informer States',
        description='sum(rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"canary-openshift-ocp-installer-e2e-.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="prow-controller-manager",job_name=~"canary-openshift-ocp-installer-e2e-.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        legend_sort='min',
        legend_sortDesc=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(targetFor("aws-fips.*-4.2", "AWS IPI FIPS"))
    .addTarget(targetFor("azure.*-4.2", "Azure IPI"))
    .addTarget(targetFor("azure-fips.*-4.2", "Azure IPI FIPS"))
    .addTarget(targetFor("gcp.*-4.2", "GCP IPI"))
    .addTarget(targetFor("gcp-fips.*-4.2", "GCP IPI FIPS"))
    .addTarget(targetFor("aws-upi.*-4.2", "AWS UPI"))
    .addTarget(targetFor("vsphere-upi.*-4.2", "vSphere UPI"))
    .addTarget(targetFor("metal.*-4.2", "Metal UPI"))
    .addTarget(targetFor("openstack.*-4.2", "Openstack")),
    gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
