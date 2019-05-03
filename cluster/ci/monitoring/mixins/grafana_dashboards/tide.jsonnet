local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;

dashboard.new(
        'tide dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addPanel(
    graphPanel.new(
        'PRs in each Tide pool',
        description="sum(pooledprs) by (org, repo, branch)",
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(pooledprs) by (org, repo, branch)'
    )), gridPos={
    h: 9,
    w: 12,
    x: 0,
    y: 0,
  })
.addPanel(
    graphPanel.new(
        'last time each subpool synced',
        description="updatetime",
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'updatetime'
    )), gridPos={
    h: 9,
    w: 12,
    x: 12,
    y: 0,
  })
.addPanel(
    graphPanel.new(
        'merges where values are the number of PRs merged together',
        description="sum(merges_sum) by (org, repo, branch)",
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(merges_sum) by (org, repo, branch)'
    )), gridPos={
    h: 9,
    w: 12,
    x: 0,
    y: 9,
  })
.addPanel(
    graphPanel.new(
        'percentage of merge with 1 PR',
        description="sum(rate(merges_bucket{le=\"1\"}[10m])) by (job) / sum(rate(merges_count[10m])) by (job)",
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(rate(merges_bucket{le=\"1\"}[10m])) by (job) / sum(rate(merges_count[10m])) by (job)'
    )), gridPos={
    h: 9,
    w: 12,
    x: 12,
    y: 9,
  })
.addPanel(
    graphPanel.new(
        'duration of the last loop of the sync controller',
        description="syncdur",
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'syncdur'
    )), gridPos={
    h: 9,
    w: 12,
    x: 0,
    y: 18,
  })
.addPanel(
    graphPanel.new(
        'duration of the last loop of the status update controller',
        description="statusupdatedur",
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'statusupdatedur'
    )), gridPos={
    h: 9,
    w: 12,
    x: 12,
    y: 18,
  })
