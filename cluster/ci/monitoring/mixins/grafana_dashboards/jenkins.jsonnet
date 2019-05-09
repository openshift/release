local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;

local legendConfig = {
        legend+: {
            sideWidth: 250
        },
    };

dashboard.new(
        'jenkins-operator dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'number of Prow jobs by type',
        description='sum(prowjobs{exported_job="jenkins-operator"}) by (type)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{exported_job="jenkins-operator"}) by (type)',
        legendFormat='{{type}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'number of Prow jobs by state',
        description='sum(prowjobs{exported_job="plank"}) by (state)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{exported_job="plank"}) by (state)',
        legendFormat='{{state}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 9,
  })
.addPanel(
    (graphPanel.new(
        'number of requests by verb',
        description='sum(jenkins_requests{exported_job="jenkins-operator"}) by (verb)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(jenkins_requests{exported_job="jenkins-operator"}) by (verb)',
        legendFormat='{{verb}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'number of requests by code',
        description='sum(jenkins_requests{exported_job="jenkins-operator"}) by (code)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(jenkins_requests{exported_job="jenkins-operator"}) by (code)',
        legendFormat='{{code}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 27,
  })
.addPanel(
    (graphPanel.new(
        'number of request reties',
        description='sum(jenkins_request_retries) by (exported_instance)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(jenkins_request_retries) by (exported_instance)',
        legendFormat='{{exported_instance}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 36,
  })
.addPanel(
    (graphPanel.new(
        'request latency',
        description='sum(rate(jenkins_request_latency_sum[1m])) by (verb)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_request_latency_sum[1m])) by (verb)',
        legendFormat='{{verb}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 45,
  })
.addPanel(
    (graphPanel.new(
        'resync period',
        description='sum(rate(resync_period_seconds_sum[1m])) by (exported_instance)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(resync_period_seconds_sum[1m])) by (exported_instance)',
        legendFormat='{{exported_instance}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 54,
  })
