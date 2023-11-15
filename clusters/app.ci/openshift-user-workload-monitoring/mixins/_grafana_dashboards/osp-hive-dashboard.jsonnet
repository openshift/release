// dashboard.jsonnet
local config = import '../config.libsonnet';
local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local statPanel = grafana.statPanel;
local prometheus = grafana.prometheus;
local operator = 'ci-framework';
local result = 'success';

local legendConfig = {
  legend+: {
    sideWidth: 350,
  },
};

local dataSource = 'prometheus-k8s-on-hive';

local hiveQueryCore(metric) =
  std.format('hive_clusterpool_clusterdeployments_%s{clusterpool_name=~"oko-.*"}', metric);

local hiveQueryRatio(metric) =
  hiveQueryCore(metric) + '/(' + hiveQueryCore('unclaimed') + '+' + hiveQueryCore('claimed') + ')';

local sumByLabel(query, label) =
  'sum(' + query + ') by(' + label + ')';

local hiveQueryRatioPercent(metric) =
  sumByLabel(hiveQueryRatio(metric), 'clusterpool_name') + '*100';

local hiveQueryTS(metric) =
  sumByLabel(hiveQueryCore(metric), 'clusterpool_name');


//-- Time series panel showing the pool usage chart -------
local hivePanelTS(metric, displayName, ds) = (
  graphPanel.new(
    std.format('OSP hive pools - %s', displayName),
    description=std.format('Number of clusters which are %s in OSP pools', displayName),
    datasource=ds,
    legend_alignAsTable=true,
    legend_rightSide=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    time_from='now-1d',
    min='0',
    stack=true,
  ) + legendConfig
).addTarget(
  prometheus.target(
    hiveQueryTS(metric),
    legendFormat='{{clusterpool_name}}',
  )
);


//-- Stat panel showing the pool occupancy rate -----------
local hivePanelStat(metric, displayName, ds) = (
  statPanel.new(
    std.format('OSP hive pools - ratio of %s clusters', displayName),
    description=std.format('Percent of cluster which are %s in OSP pools', displayName),
    datasource=ds,
    graphMode='none',
    unit='percent',
  )
).addTarget(
  prometheus.target(
    hiveQueryRatioPercent(metric),
  )
).addThreshold(
  { value: 0, color: 'semi-dark-red' }
).addThreshold(
  { value: 75, color: 'semi-dark-yellow' }
).addThreshold(
  { value: 85, color: 'semi-dark-green' }
);

//-- Create dashboard -------------------------------------
dashboard.new(
  'OSP hive pools utilization',
  time_from='now-1d',
  refresh='1m'
).addPanel(
  (
    hivePanelTS('unclaimed', 'available', dataSource)
  ),
  gridPos={ h: 12, w: 16, x: 0, y: 0 }
).addPanel(
  (
    hivePanelStat('unclaimed', 'available', dataSource)
  ),
  gridPos={ h: 12, w: 8, x: 16, y: 0 }
)
