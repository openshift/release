local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;

dashboard.new(
        'sinker dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addPanel(
    graphPanel.new(
        'existing pods',
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(sinker_pods_existing)'
    )), gridPos={
    h: 9,
    w: 12,
    x: 0,
    y: 0,
  })
.addPanel(
    graphPanel.new(
        'existing prow jobs',
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(sinker_prow_jobs_existing)'
    )), gridPos={
    h: 9,
    w: 12,
    x: 12,
    y: 0,
  })
