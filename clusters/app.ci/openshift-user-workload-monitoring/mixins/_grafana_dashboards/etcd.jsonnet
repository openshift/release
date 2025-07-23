local config =  import '../config.libsonnet';
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

local dashboardConfig = {
        uid: config._config.grafanaDashboardIDs['etcd.json'],
    };

local statPanelDefaults = {
    colorMode: 'background',
    graphMode: 'none',
    justifyMode: 'auto',
    orientation: 'auto',
    textMode: 'auto',
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
        legend_sort='current',
        legend_sortDesc=true,
    ) + legendConfig);

local defaultGridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  };

dashboard.new(
        'etcd dashboard',
        description='Dashboards for etcd monitoring in OpenShift',
        time_from='now-1h',
        schemaVersion=18,
        editable=true,
      )
.addTemplate(
  template.new(
    'cluster',
    'prometheus',
    'label_values(etcd_server_is_leader, cluster)',
    label='cluster',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
.addTemplate(
  template.new(
    'instance',
    'prometheus',
    'label_values(etcd_server_is_leader{cluster=~"${cluster}"}, instance)',
    label='instance',
    allValues='.*',
    includeAll=true,
    refresh='time',
  )
)
// Row 1: Key metrics stat panels
.addPanel(
    statPanel.new(
        'etcd Cluster Members',
        description='Number of etcd cluster members',
        datasource='prometheus',
        unit='short',
        colorMode='background',
        graphMode='none',
        justifyMode='auto',
        orientation='auto',
        reduceOptions={
            calcs: ['lastNotNull'],
            fields: '',
            values: false,
        },
        textMode='auto',
        thresholds={
            mode: 'absolute',
            steps: [
                { color: 'green', value: null },
                { color: 'yellow', value: 2 },
                { color: 'red', value: 1 },
            ],
        },
    ).addTarget(prometheus.target(
        'sum(etcd_server_id{cluster=~"${cluster}"})',
        legendFormat='Members',
    )), {
    h: 4,
    w: 4,
    x: 0,
    y: 0,
  })
.addPanel(
    statPanel.new(
        'etcd Leader',
        description='Current etcd leader status',
        datasource='prometheus',
        unit='short',
        colorMode='background',
        graphMode='none',
        justifyMode='auto',
        orientation='auto',
        reduceOptions={
            calcs: ['lastNotNull'],
            fields: '',
            values: false,
        },
        textMode='value_and_name',
        thresholds={
            mode: 'absolute',
            steps: [
                { color: 'red', value: null },
                { color: 'green', value: 1 },
            ],
        },
    ).addTarget(prometheus.target(
        'sum(etcd_server_is_leader{cluster=~"${cluster}"})',
        legendFormat='Leader',
    )), {
    h: 4,
    w: 4,
    x: 4,
    y: 0,
  })
.addPanel(
    statPanel.new(
        'etcd DB Size',
        description='etcd database size',
        datasource='prometheus',
        unit='bytes',
        colorMode='background',
        graphMode='area',
        justifyMode='auto',
        orientation='auto',
        reduceOptions={
            calcs: ['lastNotNull'],
            fields: '',
            values: false,
        },
        textMode='auto',
        thresholds={
            mode: 'absolute',
            steps: [
                { color: 'green', value: null },
                { color: 'yellow', value: 2000000000 }, // 2GB
                { color: 'red', value: 8000000000 },   // 8GB
            ],
        },
    ).addTarget(prometheus.target(
        'max(etcd_mvcc_db_total_size_in_bytes{cluster=~"${cluster}"})',
        legendFormat='DB Size',
    )), {
    h: 4,
    w: 4,
    x: 8,
    y: 0,
  })
.addPanel(
    statPanel.new(
        'etcd Proposals Failed',
        description='Failed etcd proposals per second',
        datasource='prometheus',
        unit='reqps',
        colorMode='background',
        graphMode='area',
        justifyMode='auto',
        orientation='auto',
        reduceOptions={
            calcs: ['lastNotNull'],
            fields: '',
            values: false,
        },
        textMode='auto',
        thresholds={
            mode: 'absolute',
            steps: [
                { color: 'green', value: null },
                { color: 'yellow', value: 1 },
                { color: 'red', value: 5 },
            ],
        },
    ).addTarget(prometheus.target(
        'sum(rate(etcd_server_proposals_failed_total{cluster=~"${cluster}"}[5m]))',
        legendFormat='Failed Proposals/sec',
    )), {
    h: 4,
    w: 4,
    x: 12,
    y: 0,
  })
.addPanel(
    statPanel.new(
        'Network Latency',
        description='95th percentile of network round trip time',
        datasource='prometheus',
        unit='s',
        colorMode='background',
        graphMode='area',
        justifyMode='auto',
        orientation='auto',
        reduceOptions={
            calcs: ['lastNotNull'],
            fields: '',
            values: false,
        },
        textMode='auto',
        thresholds={
            mode: 'absolute',
            steps: [
                { color: 'green', value: null },
                { color: 'yellow', value: 0.01 }, // 10ms
                { color: 'red', value: 0.1 },     // 100ms
            ],
        },
    ).addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(etcd_network_peer_round_trip_time_seconds_bucket{cluster=~"${cluster}"}[5m])) by (le))',
        legendFormat='95th percentile RTT',
    )), {
    h: 4,
    w: 4,
    x: 16,
    y: 0,
  })
.addPanel(
    statPanel.new(
        'Client Requests/sec',
        description='etcd client requests per second',
        datasource='prometheus',
        unit='reqps',
        colorMode='background',
        graphMode='area',
        justifyMode='auto',
        orientation='auto',
        reduceOptions={
            calcs: ['lastNotNull'],
            fields: '',
            values: false,
        },
        textMode='auto',
        thresholds={
            mode: 'absolute',
            steps: [
                { color: 'green', value: null },
                { color: 'yellow', value: 1000 },
                { color: 'red', value: 5000 },
            ],
        },
    ).addTarget(prometheus.target(
        'sum(rate(etcd_server_client_requests_total{cluster=~"${cluster}"}[5m]))',
        legendFormat='Client Requests/sec',
    )), {
    h: 4,
    w: 4,
    x: 20,
    y: 0,
  })
// Row 2: Request latency and throughput
.addPanel(
    myPanel('etcd Request Latency by Type',
        description='95th percentile latency for etcd requests by type'
        )
    .addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(etcd_request_duration_seconds_bucket{cluster=~"${cluster}",instance=~"${instance}"}[5m])) by (le, type))',
        legendFormat='{{type}} - 95th percentile',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.99, sum(rate(etcd_request_duration_seconds_bucket{cluster=~"${cluster}",instance=~"${instance}"}[5m])) by (le, type))',
        legendFormat='{{type}} - 99th percentile',
    )), {
    h: 9,
    w: 12,
    x: 0,
    y: 4,
  })
.addPanel(
    myPanel('etcd Request Rate by Type',
        description='Rate of etcd requests per second by type'
        )
    .addTarget(prometheus.target(
        'sum(rate(etcd_server_client_requests_total{cluster=~"${cluster}",instance=~"${instance}"}[5m])) by (type)',
        legendFormat='{{type}}',
    )), {
    h: 9,
    w: 12,
    x: 12,
    y: 4,
  })
// Row 3: Database metrics
.addPanel(
    myPanel('etcd Database Size Over Time',
        description='etcd database size growth over time'
        )
    .addTarget(prometheus.target(
        'etcd_mvcc_db_total_size_in_bytes{cluster=~"${cluster}",instance=~"${instance}"}',
        legendFormat='{{instance}}',
    )), {
    h: 9,
    w: 12,
    x: 0,
    y: 13,
  })
.addPanel(
    myPanel('etcd Keys Total',
        description='Total number of keys in etcd'
        )
    .addTarget(prometheus.target(
        'etcd_debugging_mvcc_keys_total{cluster=~"${cluster}",instance=~"${instance}"}',
        legendFormat='{{instance}}',
    )), {
    h: 9,
    w: 12,
    x: 12,
    y: 13,
  })
// Row 4: Raft consensus metrics
.addPanel(
    myPanel('etcd Raft Proposals',
        description='Rate of Raft proposals committed, applied, and failed'
        )
    .addTarget(prometheus.target(
        'sum(rate(etcd_server_proposals_committed_total{cluster=~"${cluster}"}[5m]))',
        legendFormat='Committed',
    ))
    .addTarget(prometheus.target(
        'sum(rate(etcd_server_proposals_applied_total{cluster=~"${cluster}"}[5m]))',
        legendFormat='Applied',
    ))
    .addTarget(prometheus.target(
        'sum(rate(etcd_server_proposals_failed_total{cluster=~"${cluster}"}[5m]))',
        legendFormat='Failed',
    )), {
    h: 9,
    w: 12,
    x: 0,
    y: 22,
  })
.addPanel(
    myPanel('etcd Leader Changes',
        description='Rate of etcd leader changes'
        )
    .addTarget(prometheus.target(
        'rate(etcd_server_leader_changes_seen_total{cluster=~"${cluster}"}[5m])',
        legendFormat='{{instance}}',
    )), {
    h: 9,
    w: 12,
    x: 12,
    y: 22,
  })
// Row 5: Network and disk metrics
.addPanel(
    myPanel('etcd Network Round Trip Time',
        description='Network round trip time between etcd peers'
        )
    .addTarget(prometheus.target(
        'histogram_quantile(0.50, sum(rate(etcd_network_peer_round_trip_time_seconds_bucket{cluster=~"${cluster}"}[5m])) by (le, instance, To))',
        legendFormat='{{instance}} to {{To}} - 50th percentile',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(etcd_network_peer_round_trip_time_seconds_bucket{cluster=~"${cluster}"}[5m])) by (le, instance, To))',
        legendFormat='{{instance}} to {{To}} - 95th percentile',
    )), {
    h: 9,
    w: 12,
    x: 0,
    y: 31,
  })
.addPanel(
    myPanel('etcd Disk Sync Duration',
        description='Time taken for disk syncs'
        )
    .addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket{cluster=~"${cluster}"}[5m])) by (le, instance))',
        legendFormat='{{instance}} WAL fsync - 95th percentile',
    ))
    .addTarget(prometheus.target(
        'histogram_quantile(0.95, sum(rate(etcd_disk_backend_commit_duration_seconds_bucket{cluster=~"${cluster}"}[5m])) by (le, instance))',
        legendFormat='{{instance}} Backend commit - 95th percentile',
    )), {
    h: 9,
    w: 12,
    x: 12,
    y: 31,
  })
+ dashboardConfig 