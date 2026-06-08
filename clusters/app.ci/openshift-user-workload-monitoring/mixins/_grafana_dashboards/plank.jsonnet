local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 250
        },
    };

local dashboardConfig = {
        uid: 'e1778910572e3552a935c2035ce80369',
    };

dashboard.new(
        'plank dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addTemplate(template.new(
        'cluster',
        'prometheus',
        std.format('label_values(prowjobs{job="prow-controller-manager"}, %s)', 'cluster'),
        label='cluster',
        refresh='time',
        allValues='.*',
        includeAll=true,
    ))
.addPanel(
    (graphPanel.new(
        'number of Prow jobs by type with cluster=${cluster}',
        description='sum(prowjobs{job="prow-controller-manager", cluster=~"${cluster}"}) by (type)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="prow-controller-manager", cluster=~"${cluster}"}) by (type)',
        legendFormat='{{type}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'number of Prow jobs by state with cluster=${cluster}',
        description='sum(prowjobs{job="prow-controller-manager", cluster=~"${cluster}"}) by (state)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="prow-controller-manager", cluster=~"${cluster}"}) by (state)',
        legendFormat='{{state}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 9,
  })
+ dashboardConfig
