local config =  import '../config.libsonnet';
local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local prometheus = grafana.prometheus;
local template = grafana.template;

local dashboardConfig = {
  uid: config._config.grafanaDashboardIDs['e2e_template_jobs.json'],
};

local legendConfig = {
        legend+: {
          alignAsTable: true,
          rightSide: true,
          values: true,
          max: true,
          current: true,
          sort: 'max',
          sortDesc: true,
        },
    };

local gridPosConfig = {
    h: 9,
    w: 24,
    x: 0,
    y: 9,
};

dashboard.new(
  'e2e template jobs dashboard',
  time_from='now-12h',
  schemaVersion=18,
)

.addPanel(
  (graphPanel.new(
     'CPU usage / requested',
     description='Percentage of CPU requested usage',
     datasource='prometheus-k8s',
     formatY1='percent',
   ) + legendConfig)
  .addTarget(prometheus.target(
    '100 * (sum by(pod)(label_join(pod_name:container_cpu_usage:sum, "pod", "", "pod_name")) * on(pod) group_right(label_component) label_replace(kube_pod_labels {namespace=~"ci-op-.*", label_ci_openshift_io_refs_org=~"$org", label_ci_openshift_io_refs_repo=~"$repos", label_ci_openshift_io_refs_branch=~"$branches"}, "pod", "$1", "pod", "(.*)")) / on (pod) group_left sum(label_replace(kube_pod_container_resource_requests_cpu_cores, "pod", "$1", "pod", "(.*)")) by (pod)',
    legendFormat='{{label_ci_openshift_io_refs_org}}/{{label_ci_openshift_io_refs_repo}}/{{label_ci_openshift_io_refs_branch}}/{{pod}}',
  )), gridPos=gridPosConfig
)

.addPanel(
  (graphPanel.new(
     'Memory usage / requested',
     description='Percentage of Memory requested usage',
     datasource='prometheus-k8s',
     formatY1='percent',
   ) + legendConfig)
  .addTarget(prometheus.target(
    '100 * (sum by(pod)(label_join(container_memory_working_set_bytes, "pod", "", "pod_name")) * on(pod) group_right(label_component) label_replace(kube_pod_labels {namespace=~"ci-op-.*", label_ci_openshift_io_refs_org=~"$org", label_ci_openshift_io_refs_repo=~"$repos", label_ci_openshift_io_refs_branch=~"$branches"}, "pod", "$1", "pod", "(.*)")) / on (pod) group_left sum(label_replace(kube_pod_container_resource_requests_memory_bytes, "pod", "$1", "pod", "(.*)")) by (pod)',
    legendFormat='{{label_ci_openshift_io_refs_org}}/{{label_ci_openshift_io_refs_repo}}/{{label_ci_openshift_io_refs_branch}}/{{pod}}',
  )), gridPos=gridPosConfig
)

.addTemplate(
  template.new(
    'org',
    'prometheus-k8s',
    'label_values(kube_pod_labels{namespace=~"ci-op-.*"}, label_ci_openshift_io_refs_org)',
    label='Organization',
    refresh='time',
    multi=false,
    includeAll=true,
    current='all',
  )
)

.addTemplate(
  template.new(
    'repos',
    'prometheus-k8s',
    'label_values(kube_pod_labels{namespace=~"ci-op-.*", label_ci_openshift_io_refs_org=~"$org"}, label_ci_openshift_io_refs_repo)',
    label='Repositories',
    refresh='time',
    multi=true,
    includeAll=true,
    current='all',
  )
)

.addTemplate(
  template.new(
    'branches',
    'prometheus-k8s',
    'label_values(kube_pod_labels{namespace=~"ci-op-.*", label_ci_openshift_io_refs_org=~"$org", label_ci_openshift_io_refs_repo=~"$repos"}, label_ci_openshift_io_refs_branch)',
    label='Branches',
    refresh='time',
    multi=true,
    includeAll=true,
    current='all',
  )
) + dashboardConfig
