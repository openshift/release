local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 250,
        },
    };
    
local dashboardConfig = {
        uid: 'c27162ae7ad9ce08d2dcfa2d5ce7fee8',
    };

dashboard.new(
        'deck dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addTemplate(
  template.new(
    'path',
    'prometheus',
    'label_values(deck_http_request_duration_seconds_count, path)',
    label='path',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'method',
    'prometheus',
    'label_values(deck_http_request_duration_seconds_count, method)',
    label='method',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'status',
    'prometheus',
    'label_values(deck_http_request_duration_seconds_count, status)',
    label='status',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addPanel(
    (graphPanel.new(
        'median latency with (pre-defined) paths, method ${method}, and status ${status}',
        description='histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="<path>", method=~"${method}", status=~"${status}"}[5m])) by (le))',
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
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/tide", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/tide',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/plugin-help.js", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/plugin-help.js',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/data.js", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/data.js',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/prowjobs.js", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/prowjobs.js',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/pr-data.js", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/pr-data.js',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/log", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/log',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/rerun", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/rerun',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/spyglass/", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/spyglass/',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/view/", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/view/',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/job-history/", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/job-history/',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path="/pr-history/", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='/pr-history/',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'latency percentile with path ${path}, method ${method}, and status ${status}',
        description='histogram_quantile(<phi>, sum(rate(deck_http_request_duration_seconds_bucket{path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (le))',
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
        'histogram_quantile(0.99, sum(rate(deck_http_request_duration_seconds_bucket{path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='phi=0.99',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(deck_http_request_duration_seconds_bucket{path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='phi=0.95',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(deck_http_request_duration_seconds_bucket{path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (le))',
        legendFormat='phi=0.5',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'traffic: couter by status with path ${path} and method ${method}',
        description='sum(rate(deck_http_request_duration_seconds_count{path=~"$path", method=~"$method"}[5m])) by (status)',
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
        'sum(rate(deck_http_request_duration_seconds_count{path=~"$path", method=~"$method"}[5m])) by (status)',
        legendFormat='{{status}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'status percentage with path ${path} and method ${method}',
        description='sum(rate(deck_http_request_duration_seconds_count{status=~"n..", path=~"$path", method=~"$method"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"$path"}[5m]))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
        min='0',
        max='1',
        stack=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count{status=~"2..", path=~"$path", method=~"$method"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"$path", method=~"$method"}[5m]))',
        legendFormat='2XX',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count{status=~"3..", path=~"$path", method=~"$method"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"$path", method=~"$method"}[5m]))',
        legendFormat='3XX',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count{status=~"4..", path=~"$path", method=~"$method"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"$path", method=~"$method"}[5m]))',
        legendFormat='4XX',
    ))
    .addTarget(prometheus.target(
        'sum(rate(deck_http_request_duration_seconds_count{status=~"5..", path=~"$path", method=~"$method"}[5m]))/sum(rate(deck_http_request_duration_seconds_count{path=~"$path", method=~"$method"}[5m]))',
        legendFormat='5XX',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'apdex score with target 2.5s and tolerance 10s, path ${path}, method ${method}, and status ${status}',
        description='( sum(rate(deck_http_request_duration_seconds_bucket{le="2.5", path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (job) + sum(rate(deck_http_request_duration_seconds_bucket{le="10", path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (job) ) / 2 / sum(rate(deck_http_request_duration_seconds_count{path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (job)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        min='0',
        max='1',
    ) + legendConfig)
    .addTarget(prometheus.target(
        '( sum(rate(deck_http_request_duration_seconds_bucket{le="2.5", path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (job) + sum(rate(deck_http_request_duration_seconds_bucket{le="10", path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (job) ) / 2 / sum(rate(deck_http_request_duration_seconds_count{path=~"${path}", method=~"${method}", status=~"${status}"}[5m])) by (job)',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
