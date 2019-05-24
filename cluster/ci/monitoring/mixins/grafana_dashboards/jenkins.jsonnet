local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 200
        },
    };

local dashboardConfig = {
        uid: '8302dd146d3a0f790ed94c3c5ce8035c',
    };

dashboard.new(
        'jenkins-operator dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addTemplate(
  template.new(
    'job',
    'prometheus',
    'label_values(resync_period_seconds_count, job)',
    label='job',
    refresh='time',
  )
)
.addPanel(
    (graphPanel.new(
        'number of Prow jobs by type for job ${job}',
        description='sum(prowjobs{job="${job}"}) by (type)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="${job}"}) by (type)',
        legendFormat='{{type}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'number of Prow jobs by state for job ${job}',
        description='sum(prowjobs{job="${job}"}) by (state)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="${job}"}) by (state)',
        legendFormat='{{state}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 9,
  })
.addPanel(
    (graphPanel.new(
        'number of requests by verb for job ${job}',
        description='sum(rate(jenkins_requests{job="${job}"}[1m])) by (verb)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_requests{job="${job}"}[1m])) by (verb)',
        legendFormat='{{verb}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'number of requests by code for job ${job}',
        description='sum(rate(jenkins_requests{job="${job}"}[1m])) by (code)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_requests{job="${job}"}[1m])) by (code)',
        legendFormat='{{code}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 27,
  })
.addPanel(
    (graphPanel.new(
        'number of request reties for job ${job}',
        description='sum(rate(jenkins_request_retries{job="${job}"}[1m]))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_request_retries{job="${job}"}[1m]))',
        legendFormat='${job}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 36,
  })
.addPanel(
    (graphPanel.new(
        'request latency for job ${job}',
        description='sum(jenkins_request_latency_sum{job="${job}"}) by (verb)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(jenkins_request_latency_sum{job="${job}"}) by (verb)',
        legendFormat='{{verb}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 45,
  })
.addPanel(
    (graphPanel.new(
        'resync period for job ${job}',
        description='sum(resync_period_seconds_sum{job="${job}"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true, 
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(resync_period_seconds_sum{job="${job}"})',
        legendFormat='${job}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 54,
  })
+ dashboardConfig
