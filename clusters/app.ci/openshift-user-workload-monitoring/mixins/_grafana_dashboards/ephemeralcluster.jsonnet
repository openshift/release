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
        label='Total Ephemeral Clusters broken down by',
    );

local provisioningDurationOverall(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(increase(ephemeralcluster_provisioning_duration_seconds_bucket[5m])) by (le))', phi),
        legendFormat=std.format('p%d', phi * 100),
    );

local deprovisioningDurationOverall(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(increase(ephemeralcluster_deprovisioning_duration_seconds_bucket[5m])) by (le))', phi),
        legendFormat=std.format('p%d', phi * 100),
    );

local provisioningDurationByWorkflow(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(increase(ephemeralcluster_provisioning_duration_seconds_bucket{workflow=~"${workflow}"}[5m])) by (le, workflow))', phi),
        legendFormat=std.format('p%d - {{workflow}}', phi * 100),
    );

local deprovisioningDurationByWorkflow(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(increase(ephemeralcluster_deprovisioning_duration_seconds_bucket{workflow=~"${workflow}"}[5m])) by (le, workflow))', phi),
        legendFormat=std.format('p%d - {{workflow}}', phi * 100),
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
        'Total Ephemeral Clusters broken down by "${group_by}"',
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
.addPanel(
    (graphPanel.new(
        'Provisioning Duration - Overall (seconds)',
        description='Time from cluster creation to ClusterReady condition across all workflows',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
        format='s',
    ) + legendConfig)
    .addTarget(provisioningDurationOverall(0.50))
    .addTarget(provisioningDurationOverall(0.90))
    .addTarget(provisioningDurationOverall(0.95))
    .addTarget(provisioningDurationOverall(0.99)), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'Deprovisioning Duration - Overall (seconds)',
        description='Time from TestCompleted to ProwJobCompleted condition across all workflows',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
        format='s',
    ) + legendConfig)
    .addTarget(deprovisioningDurationOverall(0.50))
    .addTarget(deprovisioningDurationOverall(0.90))
    .addTarget(deprovisioningDurationOverall(0.95))
    .addTarget(deprovisioningDurationOverall(0.99)), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 27,
  })
.addPanel(
    (graphPanel.new(
        'Provisioning Duration by Workflow (seconds)',
        description='Time from cluster creation to ClusterReady condition broken down by workflow',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
        format='s',
    ) + legendConfig)
    .addTarget(provisioningDurationByWorkflow(0.50))
    .addTarget(provisioningDurationByWorkflow(0.90))
    .addTarget(provisioningDurationByWorkflow(0.95))
    .addTarget(provisioningDurationByWorkflow(0.99)), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 36,
  })
.addPanel(
    (graphPanel.new(
        'Deprovisioning Duration by Workflow (seconds)',
        description='Time from TestCompleted to ProwJobCompleted condition broken down by workflow',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
        format='s',
    ) + legendConfig)
    .addTarget(deprovisioningDurationByWorkflow(0.50))
    .addTarget(deprovisioningDurationByWorkflow(0.90))
    .addTarget(deprovisioningDurationByWorkflow(0.95))
    .addTarget(deprovisioningDurationByWorkflow(0.99)), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 45,
  })
