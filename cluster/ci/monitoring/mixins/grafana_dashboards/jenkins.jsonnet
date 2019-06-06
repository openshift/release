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
    y: 0,
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
    y: 0,
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
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'median number of request reties for job ${job}',
        description='histogram_quantile(0.5, sum(rate(jenkins_request_latency_bucket{job="${job}"}[1m])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(jenkins_request_latency_bucket{job="${job}"}[1m])) by (le))',
        legendFormat='${job}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'median resync period for job ${job}',
        description='histogram_quantile(0.5, sum(rate(resync_period_seconds_bucket{job="${job}"}[1m])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true, 
    ) + legendConfig)
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(resync_period_seconds_bucket{job="${job}"}[1m])) by (le))',
        legendFormat='${job}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
