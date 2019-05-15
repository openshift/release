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
        description='sum(prowjobs{exported_job="jenkins-operator"}) by (state)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{exported_job="jenkins-operator"}) by (state)',
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
        description='sum(rate(jenkins_requests{exported_job="jenkins-operator"}[1m])) by (verb)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_requests{exported_job="jenkins-operator"}[1m])) by (verb)',
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
        description='sum(rate(jenkins_requests{exported_job="jenkins-operator"}[1m])) by (code)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_requests{exported_job="jenkins-operator"}[1m])) by (code)',
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
        description='sum(rate(jenkins_request_retries{exported_instance=~"<jenkins-operator-name>-.*"}[1m]))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(jenkins_request_retries{exported_instance=~"kata-jenkins-operator-.*"}[1m]))',
        legendFormat='kata-jenkins-operator',
    ))
    .addTarget(prometheus.target(
        'sum(rate(jenkins_request_retries{exported_instance=~"jenkins-dev-operator-.*"}[1m]))',
        legendFormat='jenkins-dev-operator',
    ))
    .addTarget(prometheus.target(
        'sum(rate(jenkins_request_retries{exported_instance=~"jenkins-operator-.*"}[1m]))',
        legendFormat='jenkins-operator',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 36,
  })
.addPanel(
    (graphPanel.new(
        'request latency',
        description='sum(jenkins_request_latency_sum) by (verb)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(jenkins_request_latency_sum) by (verb)',
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
        description='sum(resync_period_seconds_sum{exported_instance=~"<jenkins-operator-name>-.*"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(resync_period_seconds_sum{exported_instance=~"kata-jenkins-operator-.*"})',
        legendFormat='kata-jenkins-operator',
    )).addTarget(prometheus.target(
        'sum(resync_period_seconds_sum{exported_instance=~"jenkins-dev-operator-.*"})',
        legendFormat='jenkins-dev-operator',
    )).addTarget(prometheus.target(
        'sum(resync_period_seconds_sum{exported_instance=~"jenkins-operator-.*"})',
        legendFormat='jenkins-operator',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 54,
  })
