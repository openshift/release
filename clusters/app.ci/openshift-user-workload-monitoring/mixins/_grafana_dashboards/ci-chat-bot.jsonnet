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
        uid: config._config.grafanaDashboardIDs['ci-chat-bot.json'],
    };

local histogramQuantileSync(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_sync_duration_seconds_bucket[${range}])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

local histogramQuantileReadyDuration(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_ready_duration_minutes_bucket[${range}])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

local histogramQuantileAuthDuration(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_auth_duration_minutes_bucket[${range}])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

local histogramQuantileConsoleDuration(phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_console_duration_minutes_bucket[${range}])) by (le))', phi),
        legendFormat=std.format('phi=%s', phi),
    );

dashboard.new(
        'ci-chat-bot dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addTemplate(
  {
        "allValue": null,
        "current": {
          "text": "3h",
          "value": "3h"
        },
        "hide": 0,
        "includeAll": false,
        "label": "range",
        "multi": false,
        "name": "range",
        "options":
        [
          {
            "selected": false,
            "text": '%s' % r,
            "value": '%s'% r,
          },
          for r in ['24h', '12h']
        ] +
        [
          {
            "selected": true,
            "text": '3h',
            "value": '3h',
          }
        ] +
        [
          {
            "selected": false,
            "text": '%s' % r,
            "value": '%s'% r,
          },
          for r in ['1h', '30m', '15m', '10m', '5m']
        ],
        "query": "3h,1h,30m,15m,10m,5m",
        "skipUrlSync": false,
        "type": "custom"
      }
)
.addPanel(
    (graphPanel.new(
        'Time to Auth-Ready in minutes',
        description='histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_ready_duration_minutes_bucket[${range}])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileAuthDuration('0.95'))
    .addTarget(histogramQuantileAuthDuration('0.75'))
    .addTarget(histogramQuantileAuthDuration('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 1,
  })
.addPanel(
    (graphPanel.new(
        'Time to Console-Ready in minutes',
        description='histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_console_duration_minutes_bucket[${range}])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileConsoleDuration('0.95'))
    .addTarget(histogramQuantileConsoleDuration('0.75'))
    .addTarget(histogramQuantileConsoleDuration('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 1,
  })
.addPanel(
    (graphPanel.new(
        'Time to ROSA-Ready in minutes',
        description='histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_ready_duration_minutes_bucket[${range}])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileReadyDuration('0.95'))
    .addTarget(histogramQuantileReadyDuration('0.75'))
    .addTarget(histogramQuantileReadyDuration('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 1,
  })
.addPanel(
    (graphPanel.new(
        'ROSA Sync Time in seconds',
        description='histogram_quantile(%s, sum(rate(ci_chat_bot_rosa_sync_duration_seconds_bucket[${range}])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileSync('0.95'))
    .addTarget(histogramQuantileSync('0.75'))
    .addTarget(histogramQuantileSync('0.5')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 1,
  })
.addPanel(
    (graphPanel.new(
        'ROSA Operation Error Rate',
        description='sum(increase(cluster_bot_error_rate[${range}])) by (error)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(increase(cluster_bot_error_rate[${range}])) by (error)',
        legendFormat='{{error}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
