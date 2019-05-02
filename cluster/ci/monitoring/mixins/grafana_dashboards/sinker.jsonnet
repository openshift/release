local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local row = grafana.row;
local prometheus = grafana.prometheus;

local sumRow = row.new()
                .addPanel(
                    graphPanel.new(
                        'existing pods',
                        datasource='prometheus',
                        span=12,
                    )
                    .addTarget(prometheus.target(
                        'sum(sinker_pods_existing)'
                    )))
                .addPanel(
                    graphPanel.new(
                        'existing prow jobs',
                        datasource='prometheus',
                        span=12,
                    )
                    .addTarget(prometheus.target(
                        'sum(sinker_prow_jobs_existing)'
                    ))
);

dashboard.new(
        'sinker dashboard',
        time_from='now-1h',
      )
      .addRow(sumRow)
