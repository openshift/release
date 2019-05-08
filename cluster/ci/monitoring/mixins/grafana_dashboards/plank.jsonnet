local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;

local legendConfig = {
        legend+: {
            sideWidth: 500
        },
    };

dashboard.new(
        'plank dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'ProwJobs',
        description="The number of ProwJobs.",
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{exported_job="plank"}) by (job_name, type, state)',
        legendFormat='{{job_name}}:{{type}}:{{state}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
