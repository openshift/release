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
        uid: config._config.grafanaDashboardIDs['clusterpool.json'],
    };

local statePanel(iaas, displayName) = (graphPanel.new(
    std.format('%s Quota Leases by State', displayName),
    description=std.format('sum(boskos_resources{type="%s-quota-slice",state!="other"}) by (state)', iaas),
    datasource='prometheus',
    legend_alignAsTable=true,
    legend_rightSide=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
    stack=true,
  ) + legendConfig)
  .addTarget(prometheus.target(
    std.format('sum(boskos_resources{type="%s-quota-slice",state!="other"}) by (state)', iaas),
    legendFormat='{{state}}',
  ));

dashboard.new(
        'Cluster Pool Dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'Running Clusters by cluster pool name',
        description='sum(hive_clusterpool_clusterdeployments_claimed{clusterpool_name!~"fake-.*"}) by (clusterpool_name)+sum(hive_clusterpool_clusterdeployments_unclaimed{clusterpool_name!~"fake-.*"}) by (clusterpool_name)',
        datasource='prometheus-k8s-on-hive',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(hive_clusterpool_clusterdeployments_claimed{clusterpool_name!~"fake-.*"}) by (clusterpool_name)+sum(hive_clusterpool_clusterdeployments_unclaimed{clusterpool_name!~"fake-.*"}) by (clusterpool_name)',
        legendFormat='{{clusterpool_name}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'ci-ocp on AWS Quota',
        description='',
        datasource='prometheus-k8s-on-hive',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_max=true,
        legend_min=true,
        legend_current=true,
        legend_sortDesc=true,
        min='0',
        stack=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(hive_clusterpool_clusterdeployments_claimed{clusterpool_name=~"ci-ocp-.*-aws-.*"})',
        legendFormat='claimed',
    ))
    .addTarget(prometheus.target(
        'sum(hive_clusterpool_clusterdeployments_unclaimed{clusterpool_name=~"ci-ocp-.*-aws-.*"})',
        legendFormat='unclaimed',
    )), gridPos = {
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })

+ dashboardConfig
