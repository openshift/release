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

local mytemplate(name) = template.new(
        name,
        'prometheus',
        std.format('label_values(ephemeralcluster_count, %s)', name),
        label=name,
        allValues='.*',
        includeAll=true,
        refresh='time',
    );

local groupByTemplate = template.custom(
        'group_by',
        'konflux_cluster,konflux_tenant,cluster_profile,workflow,phase',
        'phase',
        label='Break down by',
    );

dashboard.new(
        'Ephemeral Cluster Dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addTemplate(mytemplate('konflux_cluster'))
.addTemplate(mytemplate('konflux_tenant'))
.addTemplate(mytemplate('cluster_profile'))
.addTemplate(mytemplate('workflow'))
.addTemplate(mytemplate('phase'))
.addTemplate(groupByTemplate)
.addPanel(
    (graphPanel.new(
        'Total Ephemeral Clusters',
        description='sum(ephemeralcluster_count)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(ephemeralcluster_count{konflux_cluster=~"${konflux_cluster}",konflux_tenant=~"${konflux_tenant}",cluster_profile=~"${cluster_profile}",workflow=~"${workflow}",phase=~"${phase}"})',
        legendFormat='total',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'Break down by "${group_by}"',
        description='ephemeralcluster_count grouped by selected label',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        legend_sortDesc=true,
        min='0',
        stack=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum by (${group_by}) (ephemeralcluster_count{konflux_cluster=~"${konflux_cluster}",konflux_tenant=~"${konflux_tenant}",cluster_profile=~"${cluster_profile}",workflow=~"${workflow}",phase=~"${phase}"})',
        legendFormat='{{${group_by}}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 9,
  })
