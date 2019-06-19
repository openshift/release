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
        uid: '6829209d59479d48073d09725ce807fa',
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
    'label_values(prowjobs{job="plank"}, org)',
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
    'label_values(prowjobs{job="plank", org=~"${org}"}, repo)',
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
    'label_values(prowjobs{job="plank", org=~"${org}", repo=~"${repo}"}, base_ref)',
    label='base_ref',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addPanel(
    (graphPanel.new(
        'Job Success Rates for pre-defined job names and org/repo@branch ${org}:${repo}:${base_ref}',
        description='sum(prowjobs{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~"branch-.*-images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"branch-.*-images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='branch-.*-images',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~"release-.*-4.1",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"release-.*-4.1",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='release-.*-4.1',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~"release-.*-4.2",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"release-.*-4.2",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='release-.*-4.2',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~"release-.*-upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"release-.*-upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
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
        description='sum(prowjobs{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",state="success"})/sum(prowjobs{job="plank",job_name=~"<job_name_expr>",job_name!~"rehearse.*",state=~"success|failure"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~"release-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"release-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='release-.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~"pull-ci-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"pull-ci-.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
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
        description='sum(prowjobs{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state="success"}) by (base_ref)/sum(prowjobs{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state=~"success|failure"})  by (base_ref)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state="success"}) by (base_ref)/sum(prowjobs{job="plank", job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"^(master|release-4.[0-9]+|openshift-4.[0-9]+)$", state=~"success|failure"})  by (base_ref)',
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
        description='sum(prowjobs{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*images",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*images',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*e2e.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*e2e.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*e2e.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*upgrade.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*upgrade.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*unit.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*unit.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*unit.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*integration.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*integration.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
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
        description='sum(prowjobs{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~"<regex>",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_min=true,
        min='0',
        max='1',
        formatY1='percentunit',
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*-aws.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*-aws.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*-aws.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*-vsphere.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*-vsphere.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*-vsphere.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*-gcp.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*-gcp.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*-gcp.*',
    ))
    .addTarget(prometheus.target(
        'sum(prowjobs{job="plank",job_name=~".*-azure.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state="success"})/sum(prowjobs{job="plank",job_name=~".*-azure.*",job_name!~"rehearse.*",org=~"${org}",repo=~"${repo}",base_ref=~"${base_ref}",state=~"success|failure"})',
        legendFormat='.*-azure.*',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })
+ dashboardConfig
