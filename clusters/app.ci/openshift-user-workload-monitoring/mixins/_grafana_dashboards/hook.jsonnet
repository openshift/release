local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local singlestat = grafana.singlestat;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 250
        },
    };

local dashboardConfig = {
        uid: '6123f547a129441c2cdeac6c5ce802eb',
    };

dashboard.new(
        'hook dashboard',
        time_from='now-1h',
        schemaVersion=18,
      )
.addTemplate(
  template.new(
    'plugin',
    'prometheus',
    'label_values(prow_plugin_handle_duration_seconds_bucket, plugin)',
    label='plugin',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'event_type',
    'prometheus',
    'label_values(prow_plugin_handle_duration_seconds_bucket, event_type)',
    label='event_type',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'action',
    'prometheus',
    'label_values(prow_plugin_handle_duration_seconds_bucket, action)',
    label='action',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addPanel(
    singlestat.new(
        'webhook counter',
        description='sum(prow_webhook_counter)',
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(prow_webhook_counter)',
        instant=true,
    )), gridPos={
    h: 4,
    w: 12,
    x: 0,
    y: 0,
  })
.addPanel(
    singlestat.new(
        'webhook response codes',
        description='sum(prow_webhook_response_codes)',
        datasource='prometheus',
    )
    .addTarget(prometheus.target(
        'sum(prow_webhook_response_codes)',
        instant=true,
    )), gridPos={
    h: 4,
    w: 12,
    x: 12,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'incoming webhooks by event type',
        description='sum(rate(prow_webhook_counter[1m])) by (event_type)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prow_webhook_counter[1m])) by (event_type)',
        legendFormat='{{event_type}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 4,
  })
.addPanel(
    (graphPanel.new(
        'webhook response codes',
        description='sum(rate(prow_webhook_response_codes[1m])) by (response_code)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prow_webhook_response_codes[1m])) by (response_code)',
        legendFormat='{{response_code}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 12,
    y: 13,
  })
.addPanel(
    (graphPanel.new(
        'configmap capacities',
        description='prow_configmap_size_bytes / 1048576',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_sort='current',
        legend_sortDesc=true,
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'prow_configmap_size_bytes / 1048576',
        legendFormat='{{namespace}}/{{name}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 12,
    y: 13,
  })
.addPanel(
    (graphPanel.new(
        'Response latency percentiles for event type ${event_type}, action ${action} by plugin ${plugin}',
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
        'histogram_quantile(0.99, sum(rate(prow_plugin_handle_duration_seconds_bucket{plugin=~"${plugin}", event_type=~"${event_type}", action=~"${action}"}[5m])) by (le))',
        legendFormat='phi=0.99',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(prow_plugin_handle_duration_seconds_bucket{plugin=~"${plugin}", event_type=~"${event_type}", action=~"${action}"}[5m])) by (le))',
        legendFormat='phi=0.95',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.5, sum(rate(prow_plugin_handle_duration_seconds_bucket{plugin=~"${plugin}", event_type=~"${event_type}", action=~"${action}"}[5m])) by (le))',
        legendFormat='phi=0.5',
    )), gridPos={
    h: 9,
    w: 24,
    x: 12,
    y: 13,
  })
+ dashboardConfig
