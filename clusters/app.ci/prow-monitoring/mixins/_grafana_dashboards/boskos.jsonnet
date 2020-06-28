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
        uid: config._config.grafanaDashboardIDs['boskos.json'],
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
        'Boskos Dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'Running Clusters by Platform',
        description='sum(label_replace(boskos_resources{state="leased"}, "type", "$1", "type", "(.*)-quota-slice")) by(type)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(label_replace(boskos_resources{state="leased"}, "type", "$1", "type", "(.*)-quota-slice")) by(type)',
        legendFormat='{{type}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(statePanel(iaas="aws", displayName="AWS"), gridPos={h: 9, w: 24, x: 0, y: 0})
.addPanel(statePanel(iaas="gcp", displayName="GCP"), gridPos={h: 9, w: 24, x: 0, y: 0})
.addPanel(statePanel(iaas="azure4", displayName="Azure"), gridPos={h: 9, w: 24, x: 0, y: 0})
.addPanel(statePanel(iaas="vsphere", displayName="vSphere"), gridPos={h: 9, w: 24, x: 0, y: 0})
.addPanel(statePanel(iaas="packet", displayName="Packet.net"), gridPos={h: 9, w: 24, x: 0, y: 0})
.addPanel(statePanel(iaas="openstack", displayName="OpenStack"), gridPos={h: 9, w: 24, x: 0, y: 0})
.addPanel(statePanel(iaas="openstack-vexxhost", displayName="OpenStack Vexxhost"), gridPos={h: 9, w: 24, x: 0, y: 0})
+ dashboardConfig
