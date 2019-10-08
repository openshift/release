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
        uid: config._config.grafanaDashboardIDs['configresolver.json'],
    };

local histogramQuantileReload(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(configresolver_config_reload_duration_seconds_bucket[15m])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

local histogramQuantileDuration(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(configresolver_http_request_duration_seconds_bucket[15m])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

local histogramQuantileSize(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(configresolver_http_response_size_bytes_bucket[15m])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

dashboard.new(
        'ci-operator-configresolver dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'Latency Distribution for HTTP Requests',
        description='histogram_quantile(%s, sum(rate(configresolver_http_request_duration_seconds_bucket[15m])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileDuration('0.99'))
    .addTarget(histogramQuantileDuration('0.95'))
    .addTarget(histogramQuantileDuration('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'Size Distribution for HTTP Requests',
        description='histogram_quantile(%s, sum(rate(configresolver_http_response_size_bytes_bucket[15m])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileSize('0.99'))
    .addTarget(histogramQuantileSize('0.95'))
    .addTarget(histogramQuantileSize('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'Latency Distribution for Reloading Configs from Disk',
        description='histogram_quantile(%s, sum(rate(configresolver_config_reload_duration_seconds_bucket[15m])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileReload('0.99'))
    .addTarget(histogramQuantileReload('0.95'))
    .addTarget(histogramQuantileReload('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'Config Resolver Error Rate',
        description='sum(increase(configresolver_error_rate[4h])) by (error)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(increase(configresolver_error_rate[4h])) by (error)',
        legendFormat='{{error}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
