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
          "text": "30m",
          "value": "30m"
        },
        "hide": 0,
        "includeAll": false,
        "label": "range",
        "multi": false,
        "name": "range",
        "options": [
          {
            "selected": false,
            "text": "3h",
            "value": "3h"
          },
          {
            "selected": false,
            "text": "1h",
            "value": "1h"
          },
          {
            "selected": true,
            "text": "30m",
            "value": "30m"
          },
          {
            "selected": false,
            "text": "15m",
            "value": "15m"
          },
          {
            "selected": false,
            "text": "10m",
            "value": "10m"
          },
          {
            "selected": false,
            "text": "5m",
            "value": "5m"
          }
        ],
        "query": "3h,1h,30m,15m,10m,5m",
        "skipUrlSync": false,
        "type": "custom"
      }
)
.addPanel(
    (graphPanel.new(
        'Job Success Rates for pre-defined job names and org/repo@branch ${org}:${repo}:${base_ref}',
        description='sum(rate(prowjob_state_transitions{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
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
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"branch-.*-images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"branch-.*-images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='branch-.*-images',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*-4.1",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*-4.1",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='release-.*-4.1',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*-4.2",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*-4.2",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='release-.*-4.2',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*-upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*-upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='release-.*-upgrade.*',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'Release Job versus Pull Request Job Success Rates for org/repo@branch ${org}:${repo}:${base_ref}',
        description='sum(rate(prowjob_state_transitions{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",state=~"success|failure"}[${range}]))',
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
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"release-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='release-.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~"pull-ci-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"pull-ci-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='pull-ci-.*',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'Job States by Branch for org/repo@branch ${org}:${repo}',
        description='sum(rate(prowjob_state_transitions{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state="success"}[${range}])) by (base_ref)/sum(rate(prowjob_state_transitions{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state=~"success|failure"}[${range}]))  by (base_ref)',
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
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state="success"}[${range}])) by (base_ref)/sum(rate(prowjob_state_transitions{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state=~"success|failure"}[${range}]))  by (base_ref)',
        legendFormat='{{base_ref}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'Job States by Type for org/repo@branch ${org}:${repo}:${base_ref}',
        description='sum(rate(prowjob_state_transitions{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
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
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*images',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*e2e.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*e2e.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*e2e.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*upgrade.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*unit.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*unit.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*unit.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*integration.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*integration.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*integration.*',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
.addPanel(
    (graphPanel.new(
        'Job States by Platform for org/repo@branch ${org}:${repo}:${base_ref}',
        description='sum(rate(prowjob_state_transitions{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
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
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-aws.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-aws.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*-aws.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-vsphere.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-vsphere.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*-vsphere.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-gcp.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-gcp.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*-gcp.*',
    ))
    .addTarget(prometheus.target(
        'sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-azure.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"}[${range}]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~".*-azure.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"}[${range}]))',
        legendFormat='.*-azure.*',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
