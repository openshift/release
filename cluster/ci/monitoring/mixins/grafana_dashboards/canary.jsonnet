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

dashboard.new(
        'Release-Informing Jobs Dashboard',
        time_from='now-1w',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'Canary Release Informer States',
        description='sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
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
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-aws-fips.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-aws-fips.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='AWS IPI FIPS',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-azure.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-azure.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='Azure IPI',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-azure-fips.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-azure-fips.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='Azure IPI FIPS',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-gcp.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-gcp.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='GCP IPI',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-gcp-fips.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-gcp-fips.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='GCP IPI FIPS',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-aws-upi.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-aws-upi.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='AWS UPI',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-vsphere-upi.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-vsphere-upi.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='VSphere UPI',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-metal.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-metal.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='Metal UPI',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-openstack.*-4.2",job_name!~"rehearse.*",state="success"}[48h]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"canary-openshift-ocp-installer-e2e-openstack.*-4.2",job_name!~"rehearse.*",state=~"success|failure"}[48h]))',
        legendFormat='Openstack',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
