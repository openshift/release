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
        uid: config._config.grafanaDashboardIDs['boskos_acquire.json'],
    };

local histogramQuantileDuration(phi, extra='') = prometheus.target(
        std.format('histogram_quantile(%s, sum(rate(boskos_acquire_duration_seconds_bucket%s[${range}])) by (le))', [phi, extra]),
        legendFormat=std.format('phi=%s', phi),
    );

local mytemplate(name, labelInQuery) = template.new(
        name,
        'prometheus',
        std.format('label_values(boskos_acquire_duration_seconds_bucket, %s)', labelInQuery),
        label=name,
        allValues='.*',
        includeAll=true,
        refresh='time',
    );

dashboard.new(
        'Boskos Acquire Dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addTemplate(mytemplate('type', 'type'))
.addTemplate(mytemplate('state', 'state'))
.addTemplate(mytemplate('dest', 'dest'))
.addTemplate(mytemplate('has_request_id', 'has_request_id'))
.addTemplate(
  {
        "allValue": null,
        "current": {
          "text": "5m",
          "value": "5m"
        },
        "hide": 0,
        "includeAll": false,
        "label": "range",
        "multi": false,
        "name": "range",
        "options":
        [
          {
            "selected": true,
            "text": '5m',
            "value": '5m',
          }
        ] +
        [
          {
            "selected": false,
            "text": '%s' % r,
            "value": '%s'% r,
          },
          for r in ['10m', '15m', '30m', '1h', '3h', '12h', '24h']
        ],
        "query": "3h,1h,30m,15m,10m,5m",
        "skipUrlSync": false,
        "type": "custom"
      }
)
.addPanel(
    (graphPanel.new(
        'Latency Distribution for Resource Requests for type ${type}, state ${state}, dest ${dest}, and has_request_id ${has_request_id}',
        description='histogram_quantile(%s, sum(rate(boskos_acquire_duration_seconds_bucket[${range}])) by (le))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_avg=true,
        legend_sort='avg',
        legend_sortDesc=true,
    ) + legendConfig)
    .addTarget(histogramQuantileDuration('0.99','{path=~"${type}", status=~"${state}", dest=~="${dest}", has_request_id=~"${has_request_id}"}'))
    .addTarget(histogramQuantileDuration('0.95','{path=~"${type}", status=~"${state}", dest=~="${dest}", has_request_id=~"${has_request_id}"}'))
    .addTarget(histogramQuantileDuration('0.5','{path=~"${type}", status=~"${state}", dest=~="${dest}", has_request_id=~"${has_request_id}"}')), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 18,
  })
.addPanel(
    (graphPanel.new(
        'Request rate over ${range}',
        description='sum(increase(boskos_acquire_duration_seconds_count[${range}]))',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
       'sum(rate(boskos_acquire_duration_seconds_count{path=~"${type}", status=~"${state}", dest=~="${dest}", has_request_id=~"${has_request_id}"}[${range}])) by (type, state) >0',
       legendFormat='{{type}} {{state}}'
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
