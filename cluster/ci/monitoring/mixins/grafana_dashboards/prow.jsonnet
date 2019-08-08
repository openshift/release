local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local singlestat = grafana.singlestat;
local prometheus = grafana.prometheus;

local legendConfig = {
        legend+: {
            sideWidth: 250
        },
    };

local dashboardConfig = {
        uid: '970b051d3adfd62eb592154c5ce80377',
    };

dashboard.new(
        'prow dashboard',
        time_from='now-1d',
        schemaVersion=18,
      )
.addPanel(
    (graphPanel.new(
        'up',
        description='sum by(job) (up)',
        datasource='prometheus',
        legend_alignAsTable=true,
        legend_rightSide=true,
    ) + legendConfig)
    .addTarget(prometheus.target(
        'sum by(job) (up)',
        legendFormat='{{job}}',
    )), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  })

.addPanel(
  (graphPanel.new(
     'CPU',
     description='CPU usage',
     datasource='prometheus-k8s',
     legend_alignAsTable=true,
     legend_rightSide=true,
   ) + legendConfig)
  .addTarget(
    prometheus.target(
      'sum(pod_name:container_cpu_usage:sum{namespace="ci",container_name!="POD"} * on (pod_name) group_left(label_component) label_replace(kube_pod_labels{pod!="",label_app="prow"}, "pod_name", "$1", "pod", "(.*)")) by (label_component)',
      legendFormat='{{label_component}}',
    )
  ), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  }
)

.addPanel(
  (graphPanel.new(
     'Memory',
     description='Memory usage',
     datasource='prometheus-k8s',
     legend_alignAsTable=true,
     legend_rightSide=true,
     formatY1='decbytes',
   ) + legendConfig)
  .addTarget(
    prometheus.target(
      'sum(container_memory_working_set_bytes{namespace="ci",container_name!="POD"} * on (pod_name) group_left(label_component) label_replace(kube_pod_labels{pod!="",label_app="prow"}, "pod_name", "$1", "pod", "(.*)")) by (label_component)',
      legendFormat='{{label_component}}'
    )
  ), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  }
)

.addPanel(
  (graphPanel.new(
     'Ephemeral storage',
     description='Ephemeral storage',
     datasource='prometheus-k8s',
     legend_alignAsTable=true,
     legend_rightSide=true,
     formatY1='decbytes',
   ) + legendConfig)
  .addTarget(
    prometheus.target(
      'sum(pod_name:container_fs_usage_bytes:sum{namespace="ci",container_name!="POD"} * on (pod_name) group_left(label_component) label_replace(kube_pod_labels{pod!="",label_app="prow"}, "pod_name", "$1", "pod", "(.*)")) by (label_component)',
      legendFormat='{{label_component}}',
    )
  ), gridPos={
    h: 9,
    w: 24,
    x: 0,
    y: 0,
  }
)
+ dashboardConfig
