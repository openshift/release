local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 500,
        },
    };

dashboard.new(
        'deck dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'latency: avg request duration',
        description='sum(rate(deck_http_request_duration_seconds_sum[5m])) without (path)/sum(rate(deck_http_request_duration_seconds_count[5m])) without (path)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum[5m])) without (path)/sum(rate(deck_http_request_duration_seconds_count[5m])) without (path)',
        legendFormat='{{pod}}:{{method}}:{{status}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'latency by (pre-defined) path: avg request duration',
        description='sum(rate(deck_http_request_duration_seconds_sum{path=~"<path_expr>"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"<path_expr>"}[5m]))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/tide.js.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/tide.js.*"}[5m]))',
        legendFormat='/tide.js.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/tide-history.js.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/tide-history.js.*"}[5m]))',
        legendFormat='/tide-history.js.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/plugin-help.js.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/plugin-help.js.*"}[5m]))',
        legendFormat='/plugin-help.js.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/data.js.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/data.js.*"}[5m]))',
        legendFormat='/data.js.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/prowjobs.js.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/prowjobs.js.*"}[5m]))',
        legendFormat='/prowjobs.js.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/pr-data.js.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/pr-data.js.*"}[5m]))',
        legendFormat='/pr-data.js.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/log.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/log.*"}[5m]))',
        legendFormat='/log.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/rerun.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/rerun.*"}[5m]))',
        legendFormat='/rerun.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/spyglass/static/.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/spyglass/static/.*"}[5m]))',
        legendFormat='/spyglass/static/.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/spyglass/lens/.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/spyglass/lens/.*"}[5m]))',
        legendFormat='/spyglass/lens/.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/view/.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/view/.*"}[5m]))',
        legendFormat='/view/.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/job-history/.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/job-history/.*"}[5m]))',
        legendFormat='/job-history/.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"/pr-history/.*"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"/pr-history/.*"}[5m]))',
        legendFormat='/pr-history/.*',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
/* will cause slow UI up to the number of paths
    TODO: try recording rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
.addPanel(
    (graphPanel.new(
        'latency by path: avg request duration',
        description='sum(rate(deck_http_request_duration_seconds_sum[5m])) by (path)/sum(rate(deck_http_request_duration_seconds_count[5m])) by (path)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum[5m])) by (path)/sum(rate(deck_http_request_duration_seconds_count[5m])) by (path)',
        legendFormat='{{path}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
*/
.addPanel(
    (graphPanel.new(
        'latency of the selected path by status: ${path}',
        description='sum(rate(deck_http_request_duration_seconds_sum{path=~"${path}"}[5m])) by (status)/sum(rate(deck_http_request_duration_seconds_count{path=~"${path}"}[5m])) by (status)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_sum{path=~"${path}"}[5m])) by (status)/sum(rate(deck_http_request_duration_seconds_count{path=~"${path}"}[5m])) by (status)',
        legendFormat='{{status}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'traffic: couter by status',
        description='sum(rate(deck_http_request_duration_seconds_count[5m])) by (status)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count[5m])) by (status)',
        legendFormat='{{status}}',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count{status!~"2.."}[5m]))',
        legendFormat='non-2..',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'status percentage',
        description='sum(deck_http_request_duration_seconds_count{status=~"<status_exp>"})/sum(deck_http_request_duration_seconds_count)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
        
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"2.."})/sum(deck_http_request_duration_seconds_count)',
        legendFormat='2..',
    ))
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"3.."})/sum(deck_http_request_duration_seconds_count)',
        legendFormat='3..',
    ))
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"4.."})/sum(deck_http_request_duration_seconds_count)',
        legendFormat='4..',
    ))
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"5.."})/sum(deck_http_request_duration_seconds_count)',
        legendFormat='5..',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addTemplate(
  template.new(
    'path',
    'prometheus',
    'label_values(deck_http_request_duration_seconds_count, path)',
    label='path',
    refresh='time',
  )
)
/* will cause slow UI up to the number of paths
.addPanel(
    (graphPanel.new(
        'non-2.. rate by path',
        description='sum(rate(deck_http_request_duration_seconds_count{status!~"2.."}[5m])) by (path)/sum(rate(deck_http_request_duration_seconds_count[5m])) by (path)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count{status!~"2.."}[5m])) by (path)',
        legendFormat='{{path}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
*/
.addPanel(
    (graphPanel.new(
        'status percentage by selected path: ${path}',
        description='sum(deck_http_request_duration_seconds_count{status=~"n..", path=~"$path"})/sum(deck_http_request_duration_seconds_count{path=~"$path"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"2..", path=~"$path"})/sum(deck_http_request_duration_seconds_count{path=~"$path"})',
        legendFormat='2..',
    ))
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"3..", path=~"$path"})/sum(deck_http_request_duration_seconds_count{path=~"$path"})',
        legendFormat='3..',
    ))
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"4..", path=~"$path"})/sum(deck_http_request_duration_seconds_count{path=~"$path"})',
        legendFormat='4..',
    ))
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count{status=~"5..", path=~"$path"})/sum(deck_http_request_duration_seconds_count{path=~"$path"})',
        legendFormat='5..',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'request couter today',
        description='sum(deck_http_request_duration_seconds_count) - sum(deck_http_request_duration_seconds_count offset 1d)',
        datasource='prometheus',
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(deck_http_request_duration_seconds_count) - sum(deck_http_request_duration_seconds_count offset 1d)',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'apdex score with target 2.5s and tolerance 10s',
        description='( sum(rate(deck_http_request_duration_seconds_bucket{le="2.5"}[5m])) by (job) + sum(rate(deck_http_request_duration_seconds_bucket{le="10"}[5m])) by (job) ) / 2 / sum(rate(deck_http_request_duration_seconds_count[5m])) by (job)',
        datasource='prometheus',
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        '( sum(rate(deck_http_request_duration_seconds_bucket{le="2.5"}[5m])) by (job) + sum(rate(deck_http_request_duration_seconds_bucket{le="10"}[5m])) by (job) ) / 2 / sum(rate(deck_http_request_duration_seconds_count[5m])) by (job)',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
