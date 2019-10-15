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
        uid: config._config.grafanaDashboardIDs['build_cop.json'],
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
        std.format('sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))', [regex, regex]),
        legendFormat=regex,
    );

local defaultGridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  };

dashboard.new(
        'build-cop dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addTemplate(
  template.new(
    'org',
    'prometheus',
    'label_values(prowjob_state_transitions{job="plank"}, org)',
    label='org',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'repo',
    'prometheus',
    'label_values(prowjob_state_transitions{job="plank", org=~"${org}"}, repo)',
    label='repo',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'base_ref',
    'prometheus',
    'label_values(prowjob_state_transitions{job="plank", org=~"${org}", repo=~"${repo}"}, base_ref)',
    label='base_ref',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
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
    myPanel('Job Success Rates for github.com/${org}/${repo}@${base_ref}',
        description='Job success rate for the org/repo/base_ref selected in the templates. Those regexes define our targets for the build-cop.'
        )
    .addTarget(myPrometheusTarget('branch-.*-images'))
    .addTarget(myPrometheusTarget('release-.*-4.1'))
    .addTarget(myPrometheusTarget('release-.*-4.2'))
    .addTarget(myPrometheusTarget('release-.*-4.3'))
    .addTarget(myPrometheusTarget('release-.*-upgrade.*'))
    .addTarget(myPrometheusTarget('release-.*4.1.*4.2.*'))
    .addTarget(myPrometheusTarget('release-.*4.2.*4.3.*')), defaultGridPos)
.addPanel(
    myPanel(
        'Presubmit and Postsubmit Job Success Rates for github.com/${org}/${repo}@${base_ref}',
        description='Job success rate for the org/repo/base_ref selected in the templates. Those regexes filter out presubmit and postsubmit jobs.',
        )
    .addTarget(myPrometheusTarget('release-.*'))
    .addTarget(myPrometheusTarget('pull-ci-.*')), defaultGridPos)
.addPanel(
    myPanel('Job States by Branch for github.com/${org}/${repo}',
        description='Job success rate for all branches and the org/repo selected in the templates.',
        )
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state="success"}[${range}])) by (base_ref)/sum(rate(prowjob_state_transitions{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state=~"success|failure"}[${range}]))  by (base_ref)',
        legendFormat='{{base_ref}}',
    )), defaultGridPos)
.addPanel(
    myPanel('Job States by Type for github.com/${org}/${repo}@${base_ref}',
        description='Job success rate for the org/repo/base_ref selected in the templates. Those regexes filter out various types of tests.',
        )
    .addTarget(myPrometheusTarget('.*images'))
    .addTarget(myPrometheusTarget('.*e2e.*'))
    .addTarget(myPrometheusTarget('.*upgrade.*'))
    .addTarget(myPrometheusTarget('.*unit.*'))
    .addTarget(myPrometheusTarget('.*integration.*')), defaultGridPos)
.addPanel(
    myPanel('Job States by Platform for github.com/${org}/${repo}@${base_ref}',
        description='Job success rate for the org/repo/base_ref selected in the templates. Those regexes filter out various types of testing platforms.',
        )
    .addTarget(myPrometheusTarget('.*-aws.*'))
    .addTarget(myPrometheusTarget('.*-vsphere.*'))
    .addTarget(myPrometheusTarget('.*-gcp.*'))
    .addTarget(myPrometheusTarget('.*-azure.*')), defaultGridPos)
+ dashboardConfig
