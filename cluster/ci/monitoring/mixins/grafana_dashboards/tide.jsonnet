local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;

dashboard.new(
        'tide dashboard',
        time_from='now-2d',
        schemaVersion=18,
      )
.addPanel(
    graphPanel.new(
        'Tide Pool Sizes',
        description="The number of PRs eligible for merge in each Tide pool.",
        datasource='prometheus',
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_alignAsTable=true,
        legend_rightSide=true,
    )
    .addTarget(prometheus.target(
        'avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch)',
        legendFormat='{{org}}/{{repo}}:{{branch}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
