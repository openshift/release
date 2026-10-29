local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local statPanel = grafana.statPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local legendConfig = {
        legend+: {
            sideWidth: 350
        },
    };

local mytemplate(name) = template.new(
        name,
        'prometheus',
        std.format('label_values(ephemeralcluster_count, %s)', name),
        label=name,
        allValues='.*',
        includeAll=true,
        refresh='time',
    );

local groupByTemplate = template.custom(
        'group_by',
        'konflux_cluster,konflux_tenant,cluster_profile,workflow,phase',
        'phase',
        label='Break down by',
    );

// Approximate the full time range for display only; queries use the exact ${__range}.
local displayRangeTemplate = template.interval(
        'display_range',
        'auto,1s',
        'auto',
        hide='variable',
        auto_count=1,
        auto_min='1ms',
    ) + {
        current+: {
            value: '$__auto_interval_display_range',
        },
    };

local clusterLabelSelector = 'konflux_cluster=~"${konflux_cluster}",konflux_tenant=~"${konflux_tenant}",cluster_profile=~"${cluster_profile}",workflow=~"${workflow}"';
local labelSelector = clusterLabelSelector + ',phase=~"${phase}"';

local phaseTransitionStat(title, phases, description='Estimated total transitions into the named phases over the selected time range.') = statPanel.new(
        title + ' (~${display_range})',
        description=description + ' Exact time range: ${__from:date} - ${__to:date}. The duration in the title is approximate.',
        datasource='prometheus',
        graphMode='none',
        reducerFunction='lastNotNull',
        unit='none',
        decimals=0,
        min=0,
    )
    .addThreshold({ color: 'blue', value: null })
    .addTarget(prometheus.target(
        std.format('sum(increase(ephemeralcluster_phase_transitions_total{%s,phase=~"%s"}[${__range}])) or vector(0)', [clusterLabelSelector, phases]),
        legendFormat='total',
        instant=true,
    ));

local durationByGroup(metric, phi) = prometheus.target(
        std.format('histogram_quantile(%s, sum(increase(%s{%s}[5m])) by (le, ${group_by}))', [phi, metric, labelSelector]),
        legendFormat=std.format('p%d - {{${group_by}}}', phi * 100),
    );

local provisioningDurationByGroup(phi) = durationByGroup(
        'ephemeralcluster_provisioning_duration_seconds_bucket', phi,
    );

local deprovisioningDurationByGroup(phi) = durationByGroup(
        'ephemeralcluster_deprovisioning_duration_seconds_bucket', phi,
    );

dashboard.new(
        'Ephemeral Cluster Dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addTemplate(mytemplate('konflux_cluster'))
.addTemplate(mytemplate('konflux_tenant'))
.addTemplate(mytemplate('cluster_profile'))
.addTemplate(mytemplate('workflow'))
.addTemplate(mytemplate('phase'))
.addTemplate(groupByTemplate)
.addTemplate(displayRangeTemplate)
.addPanel(
    phaseTransitionStat(
        'Initializing / Provisioning',
        'Initializing|Provisioning',
        description='Estimated total transitions into Initializing or Provisioning over the selected time range. A cluster progressing from Initializing to Provisioning within this time range contributes one transition to each phase.',
    ),
    gridPos={ h: 5, w: 8, x: 0, y: 0 },
  )
.addPanel(
    phaseTransitionStat('Ready', 'Ready'),
    gridPos={ h: 5, w: 8, x: 8, y: 0 },
  )
.addPanel(
    phaseTransitionStat('Initialization / Provisioning failures', 'InitializationFailed|ProvisioningFailed'),
    gridPos={ h: 5, w: 8, x: 16, y: 0 },
  )
.addPanel(
    phaseTransitionStat('Deprovisioning', 'Deprovisioning'),
    gridPos={ h: 5, w: 8, x: 0, y: 5 },
  )
.addPanel(
    phaseTransitionStat('Deprovisioned', 'Deprovisioned'),
    gridPos={ h: 5, w: 8, x: 8, y: 5 },
  )
.addPanel(
    phaseTransitionStat('Deprovisioning failures', 'DeprovisioningFailure'),
    gridPos={ h: 5, w: 8, x: 16, y: 5 },
  )
.addPanel(
    (graphPanel.new(
        'Total Ephemeral Clusters broken down by "${group_by}"',
        description='ephemeralcluster_count grouped by selected label',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        legend_sortDesc=true,
        min='0',
    ) + legendConfig)
    .addTarget(prometheus.target(
        std.format('sum by (${group_by}) (ephemeralcluster_count{%s})', labelSelector),
        legendFormat='{{${group_by}}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 10,
  })
.addPanel(
    (graphPanel.new(
        'Provisioning Duration by "${group_by}" (seconds)',
        description='Time from cluster creation to ClusterReady condition broken down by selected label',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
        format='s',
    ) + legendConfig)
    .addTarget(provisioningDurationByGroup(0.50))
    .addTarget(provisioningDurationByGroup(0.90))
    .addTarget(provisioningDurationByGroup(0.95))
    .addTarget(provisioningDurationByGroup(0.99)), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 19,
  })
.addPanel(
    (graphPanel.new(
        'Deprovisioning Duration by "${group_by}" (seconds)',
        description='Time from TestCompleted to ProwJobCompleted condition broken down by selected label',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
        legend_values=true,
        legend_current=true,
        legend_max=true,
        legend_min=true,
        min='0',
        format='s',
    ) + legendConfig)
    .addTarget(deprovisioningDurationByGroup(0.50))
    .addTarget(deprovisioningDurationByGroup(0.90))
    .addTarget(deprovisioningDurationByGroup(0.95))
    .addTarget(deprovisioningDurationByGroup(0.99)), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 28,
  })
