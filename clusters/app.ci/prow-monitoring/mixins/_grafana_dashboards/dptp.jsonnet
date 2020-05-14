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
        uid: config._config.grafanaDashboardIDs['dptp.json'],
    };

dashboard.new(
        'dptp dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'CI Operator Failure Rates by Reason',
        description='sum(rate(ci_operator_error_rate{state="failed",reason!="executing_graph:step_failed:utilizing_lease",reason!="executing_graph:step_failed:running_pod",reason!="executing_graph:step_failed:building_cache_image",reason!="executing_graph:step_failed:building_image_from_source",reason!="executing_graph:step_failed:building_project_image",reason!="executing_graph:step_failed:cloning_source",reason!="executing_graph:interrupted"}[30m])) by (reason)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(ci_operator_error_rate{state="failed",reason!="executing_graph:step_failed:utilizing_lease",reason!="executing_graph:step_failed:running_pod",reason!="executing_graph:step_failed:building_cache_image",reason!="executing_graph:step_failed:building_image_from_source",reason!="executing_graph:step_failed:building_project_image",reason!="executing_graph:step_failed:cloning_source",reason!="executing_graph:interrupted"}[30m])) by (reason)',
        legendFormat='{{reason}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'IPI-Deprovision Failures',
        description='rate(prowjob_state_transitions{job_name="periodic-ipi-deprovision",state="failure"}[30m])',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'rate(prowjob_state_transitions{job_name="periodic-ipi-deprovision",state="failure"}[30m])',
        legendFormat='{{pod}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'Plank Infra-Jobs Failures',
        description='sum(rate(prowjob_state_transitions{job="plank",job_name!~"rehearse.*",state="failure"}[5m])) by (job_name) * on (job_name) group_left prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"}',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name!~"rehearse.*",state="failure"}[5m])) by (job_name) * on (job_name) group_left prow_job_labels{job_agent="kubernetes",label_ci_openshift_io_role="infra"}',
        legendFormat='{{job_name}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig