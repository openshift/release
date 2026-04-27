local config = import '../config.libsonnet';
local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local row = grafana.row;

local legendConfig = {
  interval: '1m',
};

local hiveDS = 'prometheus-k8s-on-hive';
local prowDS = 'prometheus';
local poolFilter = 'clusterpool_name=~"odh-.*|opendatahub-.*"';

local dashboardConfig = {
  uid: config._config.grafanaDashboardIDs['odh-hive-dashboard.json'],
};

local hiveQuery(metric) =
  std.format('hive_clusterpool_clusterdeployments_%s{%s}', [metric, poolFilter]);

local hiveQueryByPool(metric) =
  std.format('sum(%s) by (clusterpool_name)', hiveQuery(metric));

//-- Row 1: Pool Capacity Overview --

local totalClustersPanel = (
  graphPanel.new(
    'ODH Total Clusters per Pool',
    description='Total clusters (claimed + unclaimed) in each ODH Hive pool',
    datasource=hiveDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
  ) + legendConfig
).addTarget(
  prometheus.target(
    hiveQueryByPool('claimed') + '+' + hiveQueryByPool('unclaimed'),
    legendFormat='{{clusterpool_name}}',
  )
);

//-- Row 2: Claimed vs Available per Pool --

local claimedUnclaimedPanel = (
  graphPanel.new(
    'ODH Claimed vs Unclaimed per Pool',
    description='Claimed and unclaimed clusters per pool. Dashed lines show the configured target unclaimed count (spec.size) for each pool.',
    datasource=hiveDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
  ) + legendConfig
).addTarget(
  prometheus.target(
    hiveQueryByPool('claimed'),
    legendFormat='claimed-{{clusterpool_name}}',
  )
).addTarget(
  prometheus.target(
    hiveQueryByPool('unclaimed'),
    legendFormat='unclaimed-{{clusterpool_name}}',
  )
).addTarget(
  prometheus.target(
    'vector(12) and on() hive_clusterpool_clusterdeployments_unclaimed{clusterpool_name="odh-4-20-aws"}',
    legendFormat='target-odh-4-20-aws (size=12)',
  )
).addTarget(
  prometheus.target(
    'vector(2) and on() hive_clusterpool_clusterdeployments_unclaimed{clusterpool_name="odh-4-19-aws"}',
    legendFormat='target-odh-4-19-aws (size=2)',
  )
).addTarget(
  prometheus.target(
    'vector(1) and on() hive_clusterpool_clusterdeployments_unclaimed{clusterpool_name="opendatahub-ocp-4-18-amd64-aws"}',
    legendFormat='target-4-18 (size=1)',
  )
) + {
  targets: super.targets,
  seriesOverrides+: [
    { alias: '/target-.*/', dashes: true, fill: 0, linewidth: 2 },
  ],
};

local assignablePanel = (
  graphPanel.new(
    'ODH Assignable Clusters per Pool',
    description='Clusters ready to be claimed right now, per pool. Red zone = pool-exhausted alert (assignable == 0 for 10m).',
    datasource=hiveDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
  ) + legendConfig
).addTarget(
  prometheus.target(
    hiveQuery('assignable'),
    legendFormat='{{clusterpool_name}}',
  )
) + {
  thresholds: [
    { value: 1, colorMode: 'critical', op: 'lt', fill: true, line: true, yaxis: 'left' },
  ],
};

//-- Row 3: Unclaimed State Breakdown per Pool --

local hivePanelForState(metric, displayName, desc) = (
  graphPanel.new(
    std.format('ODH %s Clusters per Pool', displayName),
    description=desc,
    datasource=hiveDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
  ) + legendConfig
).addTarget(
  prometheus.target(
    hiveQuery(metric),
    legendFormat='{{clusterpool_name}}',
  )
);

local installingPanel = hivePanelForState(
  'installing',
  'Installing',
  'Clusters being provisioned per pool. Dashed line = maxConcurrent (6). Orange zone = stuck-installing alert (> 5 for 30m).',
).addTarget(
  prometheus.target(
    'vector(6) and on() hive_clusterpool_clusterdeployments_installing{clusterpool_name="odh-4-20-aws"}',
    legendFormat='maxConcurrent (6)',
  )
) + {
  targets: super.targets,
  seriesOverrides+: [
    { alias: 'maxConcurrent (6)', dashes: true, fill: 0, linewidth: 2 },
  ],
  thresholds: [
    { value: 5, colorMode: 'warning', op: 'gt', fill: true, line: true, yaxis: 'left' },
  ],
};

local standbyPanel = hivePanelForState(
  'standby',
  'Standby (Hibernated)',
  'Clusters hibernated and waiting to resume per pool. These need ~20 min to wake up before they can be claimed.',
);

local brokenPanel = hivePanelForState(
  'broken',
  'Broken',
  'Failed clusters per pool. Should be 0. If non-zero, check ClusterDeployment errors on hosted-mgmt in namespace opendatahub-cluster-pool.',
);

local claimActivityPanel = (
  graphPanel.new(
    'ODH Pool Activity (Claims + Releases)',
    description='Number of times the claimed count changed per pool in a 30m window. Each claim and each release counts as one change, so the value is roughly 2x actual claims. Higher = busier pool.',
    datasource=hiveDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
  ) + legendConfig
).addTarget(
  prometheus.target(
    std.format('changes(%s[30m])', hiveQuery('claimed')),
    legendFormat='{{clusterpool_name}}',
  )
);

//-- Row 4: Prow Job Health --

local e2eSuccessFailPanel = (
  graphPanel.new(
    'ODH E2E Job Success/Failure Count',
    description='Number of successful, failed, and aborted ODH e2e Prow jobs in the last 1h window.',
    datasource=prowDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
  ) + legendConfig
).addTarget(
  prometheus.target(
    'sum(increase(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state="success"}[1h]))',
    legendFormat='success',
  )
).addTarget(
  prometheus.target(
    'sum(increase(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state="failure"}[1h]))',
    legendFormat='failure',
  )
).addTarget(
  prometheus.target(
    'sum(increase(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state="aborted"}[1h]))',
    legendFormat='aborted',
  )
);

local e2eFailureRatePanel = (
  graphPanel.new(
    'ODH E2E Failure Rate %',
    description='Percentage of ODH e2e jobs that failed over a 2h window. Red zone = high-failure-rate alert (> 50% for 30m).',
    datasource=prowDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
    max='100',
    formatY1='percent',
  ) + legendConfig
).addTarget(
  prometheus.target(
    'sum(rate(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state="failure"}[2h])) / sum(rate(prowjob_state_transitions{job_name=~".*opendatahub.*e2e.*",state=~"success|failure"}[2h])) * 100',
    legendFormat='failure rate %',
  )
) + {
  thresholds: [
    { value: 50, colorMode: 'critical', op: 'gt', fill: true, line: true, yaxis: 'left' },
  ],
};

local allJobTransitionsPanel = (
  graphPanel.new(
    'ODH Job Outcome Count (All Jobs)',
    description='Success, failure, and aborted counts for all ODH Prow jobs (not just e2e) in the last 1h window, stacked by state.',
    datasource=prowDS,
    legend_alignAsTable=true,
    legend_values=true,
    legend_max=true,
    legend_min=true,
    legend_current=true,
    legend_sortDesc=true,
    min='0',
    stack=true,
  ) + legendConfig
).addTarget(
  prometheus.target(
    'sum(increase(prowjob_state_transitions{job_name=~".*opendatahub.*",state=~"success|failure|aborted"}[1h])) by (state)',
    legendFormat='{{state}}',
  )
);

//-- Assemble dashboard --

dashboard.new(
  'ODH Hive Pools & CI Health',
  time_from='now-1d',
  refresh='1m',
  schemaVersion=18,
)

.addPanel(row.new(title='Pool Capacity Overview'), gridPos={ h: 1, w: 24, x: 0, y: 0 })
.addPanel(totalClustersPanel, gridPos={ h: 9, w: 12, x: 0, y: 1 })
.addPanel(claimedUnclaimedPanel, gridPos={ h: 9, w: 12, x: 12, y: 1 })

.addPanel(row.new(title='Unclaimed State Breakdown (assignable + installing + standby + broken = unclaimed)'), gridPos={ h: 1, w: 24, x: 0, y: 10 })
.addPanel(assignablePanel, gridPos={ h: 9, w: 12, x: 0, y: 11 })
.addPanel(installingPanel, gridPos={ h: 9, w: 12, x: 12, y: 11 })
.addPanel(standbyPanel, gridPos={ h: 9, w: 12, x: 0, y: 20 })
.addPanel(brokenPanel, gridPos={ h: 9, w: 12, x: 12, y: 20 })

.addPanel(row.new(title='Cluster Activity & Prow Job Health'), gridPos={ h: 1, w: 24, x: 0, y: 29 })
.addPanel(claimActivityPanel, gridPos={ h: 9, w: 12, x: 0, y: 30 })
.addPanel(e2eSuccessFailPanel, gridPos={ h: 9, w: 12, x: 12, y: 30 })
.addPanel(allJobTransitionsPanel, gridPos={ h: 9, w: 12, x: 0, y: 39 })
.addPanel(e2eFailureRatePanel, gridPos={ h: 9, w: 12, x: 12, y: 39 })

+ dashboardConfig
