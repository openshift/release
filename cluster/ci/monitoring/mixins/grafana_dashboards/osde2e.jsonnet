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
        uid: config._config.grafanaDashboardIDs['osde2e.json'],
    };


local myPanel(title, description) = (graphPanel.new(
        title,
        description=description,
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        legend_sort='min',
        legend_sortDesc=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig);

local myPrometheusTarget(regex) = prometheus.target(
        std.format('sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",org=~"openshift",repo=~"osde2e",base_ref=~"master",state="success"}[${range}]) or up * 0)/sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",org=~"openshift",repo=~"osde2e",base_ref=~"master",state=~"success|failure"}[${range}]))', [regex, regex]),
        legendFormat=regex,
    );

local defaultGridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  };

dashboard.new(
        'osde2e dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addTemplate(
  {
        "allValue": null,
        "current": {
          "text": "24h",
          "value": "24h"
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
            "text": '24h',
            "value": '24h',
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
    myPanel('Job Success Rates for osde2e integration regular',
        description='Job success rate for osde2e tests on integration running regularly (without an upgrade).'
        )
    .addTarget(myPrometheusTarget('periodic.*osde2e.*int-4.2'))
    .addTarget(myPrometheusTarget('periodic.*osde2e.*int-4.3')), defaultGridPos)
.addPanel(
    myPanel('Job Success Rates for osde2e stage regular',
        description='Job success rate for osde2e tests on stage running regularly (without an upgrade).'
        )
    .addTarget(myPrometheusTarget('periodic.*osde2e.*stage-4.2')), defaultGridPos)
.addPanel(
    myPanel('Job Success Rates for osde2e production regular',
        description='Job success rate for osde2e tests on production running regularly (without an upgrade).'
        )
    .addTarget(myPrometheusTarget('periodic.*osde2e.*prod-4.2')), defaultGridPos)
.addPanel(
    myPanel('Job Success Rates for osde2e integration upgrades',
        description='Job success rate for osde2e tests on integration running with upgrades.'
        )
    .addTarget(myPrometheusTarget('periodic.*osde2e.*int-4.2-4.2'))
    .addTarget(myPrometheusTarget('periodic.*osde2e.*int-4.2-4.3'))
    .addTarget(myPrometheusTarget('periodic.*osde2e.*int-4.3-4.3')), defaultGridPos)
.addPanel(
    myPanel('Job Success Rates for osde2e stage upgrades',
        description='Job success rate for osde2e tests on stage running with upgrades.'
        )
    .addTarget(myPrometheusTarget('periodic.*osde2e.*stage-4.2-4.2')), defaultGridPos)
.addPanel(
    myPanel('Job Success Rates for osde2e production upgrades',
        description='Job success rate for osde2e tests on production running with upgrades.'
        )
    .addTarget(myPrometheusTarget('periodic.*osde2e.*prod-4.2-4.2')), defaultGridPos)
+ dashboardConfig
