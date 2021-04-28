#!/bin/bash
function queue() {
  local TARGET="${1}"
  shift
  local LIVE
  LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  if [[ -n "${FILTER:-}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
  else
    "${@}" >"${TARGET}" &
  fi
}

export PATH=$PATH:/tmp/shared

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck source=/dev/null
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Gathering artifacts ..."
mkdir -p ${ARTIFACT_DIR}/pods ${ARTIFACT_DIR}/nodes ${ARTIFACT_DIR}/metrics ${ARTIFACT_DIR}/bootstrap ${ARTIFACT_DIR}/network ${ARTIFACT_DIR}/oc_cmds

oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' > /tmp/nodes
oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces --template '{{ range .items }}{{ $name := .metadata.name }}{{ $ns := .metadata.namespace }}{{ range .spec.containers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ range .spec.initContainers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ end }}' > /tmp/containers
oc --insecure-skip-tls-verify --request-timeout=5s get pods -l openshift.io/component=api --all-namespaces --template '{{ range .items }}-n {{ .metadata.namespace }} {{ .metadata.name }}{{ "\n" }}{{ end }}' > /tmp/pods-api

queue ${ARTIFACT_DIR}/config-resources.json oc --insecure-skip-tls-verify --request-timeout=5s get apiserver.config.openshift.io authentication.config.openshift.io build.config.openshift.io console.config.openshift.io dns.config.openshift.io featuregate.config.openshift.io image.config.openshift.io infrastructure.config.openshift.io ingress.config.openshift.io network.config.openshift.io oauth.config.openshift.io project.config.openshift.io scheduler.config.openshift.io -o json
queue ${ARTIFACT_DIR}/apiservices.json oc --insecure-skip-tls-verify --request-timeout=5s get apiservices -o json
queue ${ARTIFACT_DIR}/oc_cmds/apiservices oc --insecure-skip-tls-verify --request-timeout=5s get apiservices
queue ${ARTIFACT_DIR}/clusteroperators.json oc --insecure-skip-tls-verify --request-timeout=5s get clusteroperators -o json
queue ${ARTIFACT_DIR}/oc_cmds/clusteroperators oc --insecure-skip-tls-verify --request-timeout=5s get clusteroperators
queue ${ARTIFACT_DIR}/clusterversion.json oc --insecure-skip-tls-verify --request-timeout=5s get clusterversion -o json
queue ${ARTIFACT_DIR}/oc_cmds/clusterversion oc --insecure-skip-tls-verify --request-timeout=5s get clusterversion
queue ${ARTIFACT_DIR}/configmaps.json oc --insecure-skip-tls-verify --request-timeout=5s get configmaps --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/configmaps oc --insecure-skip-tls-verify --request-timeout=5s get configmaps --all-namespaces
queue ${ARTIFACT_DIR}/credentialsrequests.json oc --insecure-skip-tls-verify --request-timeout=5s get credentialsrequests --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/credentialsrequests oc --insecure-skip-tls-verify --request-timeout=5s get credentialsrequests --all-namespaces
queue ${ARTIFACT_DIR}/csr.json oc --insecure-skip-tls-verify --request-timeout=5s get csr -o json
queue ${ARTIFACT_DIR}/endpoints.json oc --insecure-skip-tls-verify --request-timeout=5s get endpoints --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/endpoints oc --insecure-skip-tls-verify --request-timeout=5s get endpoints --all-namespaces
FILTER=gzip queue ${ARTIFACT_DIR}/deployments.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get deployments --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/deployments oc --insecure-skip-tls-verify --request-timeout=5s get deployments --all-namespaces -o wide
FILTER=gzip queue ${ARTIFACT_DIR}/daemonsets.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get daemonsets --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/daemonsets oc --insecure-skip-tls-verify --request-timeout=5s get daemonsets --all-namespaces -o wide
queue ${ARTIFACT_DIR}/events.json oc --insecure-skip-tls-verify --request-timeout=5s get events --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/events oc --insecure-skip-tls-verify --request-timeout=5s get events --all-namespaces
queue ${ARTIFACT_DIR}/kubeapiserver.json oc --insecure-skip-tls-verify --request-timeout=5s get kubeapiserver -o json
queue ${ARTIFACT_DIR}/oc_cmds/kubeapiserver oc --insecure-skip-tls-verify --request-timeout=5s get kubeapiserver
queue ${ARTIFACT_DIR}/kubecontrollermanager.json oc --insecure-skip-tls-verify --request-timeout=5s get kubecontrollermanager -o json
queue ${ARTIFACT_DIR}/oc_cmds/kubecontrollermanager oc --insecure-skip-tls-verify --request-timeout=5s get kubecontrollermanager
queue ${ARTIFACT_DIR}/machineconfigpools.json oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigpools -o json
queue ${ARTIFACT_DIR}/oc_cmds/machineconfigpools oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigpools
queue ${ARTIFACT_DIR}/machineconfigs.json oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigs -o json
queue ${ARTIFACT_DIR}/oc_cmds/machineconfigs oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigs
queue ${ARTIFACT_DIR}/machinesets.json oc --insecure-skip-tls-verify --request-timeout=5s get machinesets -A -o json
queue ${ARTIFACT_DIR}/oc_cmds/machinesets oc --insecure-skip-tls-verify --request-timeout=5s get machinesets -A
queue ${ARTIFACT_DIR}/machines.json oc --insecure-skip-tls-verify --request-timeout=5s get machines -A -o json
queue ${ARTIFACT_DIR}/oc_cmds/machines oc --insecure-skip-tls-verify --request-timeout=5s get machines -A -o wide
queue ${ARTIFACT_DIR}/namespaces.json oc --insecure-skip-tls-verify --request-timeout=5s get namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/namespaces oc --insecure-skip-tls-verify --request-timeout=5s get namespaces
queue ${ARTIFACT_DIR}/nodes.json oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o json
queue ${ARTIFACT_DIR}/oc_cmds/nodes oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o wide
queue ${ARTIFACT_DIR}/openshiftapiserver.json oc --insecure-skip-tls-verify --request-timeout=5s get openshiftapiserver -o json
queue ${ARTIFACT_DIR}/oc_cmds/openshiftapiserver oc --insecure-skip-tls-verify --request-timeout=5s get openshiftapiserver
queue ${ARTIFACT_DIR}/pods.json oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/pods oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces -o wide
queue ${ARTIFACT_DIR}/persistentvolumes.json oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumes --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/persistentvolumes oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumes --all-namespaces -o wide
queue ${ARTIFACT_DIR}/persistentvolumeclaims.json oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumeclaims --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/persistentvolumeclaims oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumeclaims --all-namespaces -o wide
FILTER=gzip queue ${ARTIFACT_DIR}/replicasets.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get replicasets --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/replicasets oc --insecure-skip-tls-verify --request-timeout=5s get replicasets --all-namespaces -o wide
queue ${ARTIFACT_DIR}/rolebindings.json oc --insecure-skip-tls-verify --request-timeout=5s get rolebindings --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/rolebindings oc --insecure-skip-tls-verify --request-timeout=5s get rolebindings --all-namespaces
queue ${ARTIFACT_DIR}/roles.json oc --insecure-skip-tls-verify --request-timeout=5s get roles --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/roles oc --insecure-skip-tls-verify --request-timeout=5s get roles --all-namespaces
queue ${ARTIFACT_DIR}/services.json oc --insecure-skip-tls-verify --request-timeout=5s get services --all-namespaces -o json
queue ${ARTIFACT_DIR}/oc_cmds/services oc --insecure-skip-tls-verify --request-timeout=5s get services --all-namespaces
FILTER=gzip queue ${ARTIFACT_DIR}/statefulsets.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get statefulsets --all-namespaces -o json
queue ${ARTIFACT_DIR}/statefulsets oc --insecure-skip-tls-verify --request-timeout=5s get statefulsets --all-namespaces

FILTER=gzip queue ${ARTIFACT_DIR}/openapi.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get --raw /openapi/v2

# gather nodes first in parallel since they may contain the most relevant debugging info
while IFS= read -r i; do
  mkdir -p ${ARTIFACT_DIR}/nodes/$i
  queue ${ARTIFACT_DIR}/nodes/$i/heap oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/debug/pprof/heap
  FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/journal.gz oc --insecure-skip-tls-verify adm node-logs $i --unify=false
  FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/journal-previous.gz oc --insecure-skip-tls-verify adm node-logs $i --unify=false --boot=-1
  FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/audit.gz oc --insecure-skip-tls-verify adm node-logs $i --unify=false --path=audit/audit.log
done < /tmp/nodes

# Snapshot iptables-save on each node for debugging possible kube-proxy issues
oc --insecure-skip-tls-verify get --request-timeout=20s -n openshift-sdn -l app=sdn pods --template '{{ range .items }}{{ .metadata.name }}{{ "\n" }}{{ end }}' > /tmp/sdn-pods
while IFS= read -r i; do
  queue ${ARTIFACT_DIR}/network/iptables-save-$i oc --insecure-skip-tls-verify rsh --timeout=20 -n openshift-sdn -c sdn $i iptables-save -c
done < /tmp/sdn-pods

while IFS= read -r i; do
  file="$( echo "$i" | cut -d ' ' -f 3 | tr -s ' ' '_' )"
  queue ${ARTIFACT_DIR}/metrics/${file}-heap oc --insecure-skip-tls-verify exec $i -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8443" --config /etc/origin/master/admin.kubeconfig'
  queue ${ARTIFACT_DIR}/metrics/${file}-controllers-heap oc --insecure-skip-tls-verify exec $i -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8444" --config /etc/origin/master/admin.kubeconfig'
done < /tmp/pods-api

while IFS= read -r i; do
  file="$( echo "$i" | cut -d ' ' -f 2,3,5 | tr -s ' ' '_' )"
  FILTER=gzip queue ${ARTIFACT_DIR}/pods/${file}.log.gz oc --insecure-skip-tls-verify logs --request-timeout=20s $i
  FILTER=gzip queue ${ARTIFACT_DIR}/pods/${file}_previous.log.gz oc --insecure-skip-tls-verify logs --request-timeout=20s -p $i
done < /tmp/containers

echo "Snapshotting prometheus (may take 15s) ..."
# Use logs and data the "last" monitoring pod in order to catch issues that occur when the first prometheus pod upgrades
monitoring_pod="$( oc --insecure-skip-tls-verify get pods -n openshift-monitoring -o name | grep prometheus-k8s- | tail -1 )"
queue ${ARTIFACT_DIR}/metrics/prometheus.tar.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring "${monitoring_pod}" -- tar cvzf - -C /prometheus .

cat >> ${ARTIFACT_DIR}/custom-link-promecieus.html << EOF
<html>
<body>
<script>
function buildURL(item)
{
    item.href="https://promecieus.dptools.openshift.org/?search="+window.location.href;
    return true;
}
</script>
<a onclick="return buildURL(this)" href="">PromeCIeus</a>
</body>
</html>
EOF

FILTER=gzip queue ${ARTIFACT_DIR}/metrics/prometheus-target-metadata.json.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring "${monitoring_pod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/targets/metadata --data-urlencode 'match_target={instance!=\"\"}'"
FILTER=gzip queue ${ARTIFACT_DIR}/metrics/prometheus-config.json.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring "${monitoring_pod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/status/config"
queue ${ARTIFACT_DIR}/metrics/prometheus-tsdb-status.json oc --insecure-skip-tls-verify exec -n openshift-monitoring "${monitoring_pod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/status/tsdb"
queue ${ARTIFACT_DIR}/metrics/prometheus-runtimeinfo.json oc --insecure-skip-tls-verify exec -n openshift-monitoring "${monitoring_pod}" -- /bin/bash -c "curl -G http://localhost:9090/api/v1/status/runtimeinfo"

# Calculate metrics suitable for apples-to-apples comparison across CI runs.
# Load whatever timestamps we can, generate the metrics script, and then send it to the
# thanos-querier pod on the cluster via exec (so we don't need to have a route exposed).
echo "Saving job metrics"
cat >/tmp/generate.sh <<'GENERATE'
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# CI job metrics extraction
#
# This script gathers a number of important query metrics from the metrics
# stack in a cluster after tests are complete. It gathers metrics related to
# three phases - install, test, and overall (install start to test end).
#
# Prometheus may not have data from early in an install, and some runs may
# result in outage to prometheus, so queries have to look at measurements
# that may have gaps or be incomplete.
#
# A metric belongs in this set if it is useful in tracking a trend over time
# in the behavior of the cluster at install time or over the test run - for
# instance, by looking at the total CPU usage of the control plane, we can
# perform apples to apples comparisons between two cloud platforms and look
# for places where we are inadequate. The metrics are output to the artifacts
# dir and then are processed by the ci-search indexer cloud functions to be
# visualized by ci-search.
#
# The output of the script is a file with one JSON object per line consisting
# of:
#
# {"<name_of_metric>":<prometheus query result object>}
#
# The prometheus query result object is described here:
# https://prometheus.io/docs/prometheus/latest/querying/api/
#
# Metrics are expected to return a scalar, a vector with a single entry and
# no labels, or a vector with a single label and a single entry.
#
# This script outputs a script that is intended to be invoked against a local
# prometheus instance. In the CI environment we run this script inside the
# pod that contains the Thanos querier, but it can be used locally for testing
# against a prometheus instance running at localhost:9090.

#########

# Take as arguments a set of env vars for the phases (install, test, all) that
# contain the unix timestamp of the start and end of the two main phases, then
# calculate what we can. If a phase is missing, that may mean the test script
# could not run to completion, in which case we will not define the variable
# and some metrics will not be calculated or output. Omitting a query if it
# can't be calculate is important, because the zero value may be meaningful.
#
# - t_* is the unix timestamp at the end
# - s_* is the number of seconds the phase took
# - d_* is a prometheus duration of the phase as "<seconds>s"
t_now=$(date +%s)
if [[ -n "${TEST_TIME_INSTALL_END-}" ]]; then
  t_install=${TEST_TIME_INSTALL_END}
  if [[ -n "${TEST_TIME_INSTALL_START-}" ]]; then
    s_install="$(( TEST_TIME_INSTALL_END - TEST_TIME_INSTALL_START ))"
    d_install="${s_install}s"
  fi
fi
if [[ -n "${TEST_TIME_TEST_END-}" ]]; then
  t_test=${TEST_TIME_TEST_END}
  if [[ -n "${TEST_TIME_TEST_START-}" ]]; then
    s_test="$(( TEST_TIME_TEST_END - TEST_TIME_TEST_START ))"
    d_test="${s_test}s"
  fi
fi

if [[ -n "${TEST_TIME_TEST_START-}" || "${TEST_TIME_INSTALL_START-}" ]]; then
  t_start=${TEST_TIME_INSTALL_START:-${TEST_TIME_TEST_START}}
fi
t_all=${t_test:-${t_install:-${t_now}}}
if [[ -n "${t_start-}" ]]; then
  s_all="$(( t_all - t_start ))"
  d_all="${s_all}s"
fi

# We process this query file one line at a time - if a variable is undefined we'll skip the
# entire query.
cat > /tmp/queries <<'END'
${t_install} cluster:capacity:cpu:total:cores         sum(cluster:capacity_cpu_cores:sum)
${t_install} cluster:capacity:cpu:control_plane:cores max(cluster:capacity_cpu_cores:sum{label_node_role_kubernetes_io="master"})

${t_all}     cluster:usage:cpu:total:seconds   sum(increase(container_cpu_usage_seconds_total{id="/"}[${d_all}]))
${t_install} cluster:usage:cpu:install:seconds sum(increase(container_cpu_usage_seconds_total{id="/"}[${d_install}]))
${t_test}    cluster:usage:cpu:test:seconds    sum(increase(container_cpu_usage_seconds_total{id="/"}[${d_test}]))

${t_all}     cluster:usage:cpu:total:rate   sum(rate(container_cpu_usage_seconds_total{id="/"}[${d_all}]))
${t_install} cluster:usage:cpu:install:rate sum(rate(container_cpu_usage_seconds_total{id="/"}[${d_install}]))
${t_test}    cluster:usage:cpu:test:rate    sum(rate(container_cpu_usage_seconds_total{id="/"}[${d_test}]))

${t_all}     cluster:usage:cpu:control_plane:total:avg   avg(rate(container_cpu_usage_seconds_total{id="/"}[${d_all}]) * on(node) group_left() group by (node) (kube_node_role{role="master"}))
${t_install} cluster:usage:cpu:control_plane:install:avg avg(rate(container_cpu_usage_seconds_total{id="/"}[${d_install}]) * on(node) group_left() group by (node) (kube_node_role{role="master"}))
${t_test}    cluster:usage:cpu:control_plane:test:avg    avg(rate(container_cpu_usage_seconds_total{id="/"}[${d_test}]) * on(node) group_left() group by (node) (kube_node_role{role="master"}))

${t_all}     cluster:usage:mem:rss:control_plane:quantile label_replace(max(quantile_over_time(0.99, ((container_memory_rss{id="/"} * on(node) group_left() group by (node) (kube_node_role{role="master"})))[${d_all}:1s] )), "quantile", "0.99", "", "")
${t_all}     cluster:usage:mem:rss:control_plane:quantile label_replace(max(quantile_over_time(0.9, ((container_memory_rss{id="/"} * on(node) group_left() group by (node) (kube_node_role{role="master"})))[${d_all}:1s] )), "quantile", "0.9", "", "")
${t_all}     cluster:usage:mem:rss:control_plane:quantile label_replace(max(quantile_over_time(0.5, ((container_memory_rss{id="/"} * on(node) group_left() group by (node) (kube_node_role{role="master"})))[${d_all}:1s] )), "quantile", "0.5", "", "")

${t_all}     cluster:usage:mem:working_set:control_plane:quantile label_replace(max(quantile_over_time(0.99, ((container_memory_working_set_bytes{id="/"} * on(node) group_left() group by (node) (kube_node_role{role="master"})))[${d_all}:1s] )), "quantile", "0.99", "", "")
${t_all}     cluster:usage:mem:working_set:control_plane:quantile label_replace(max(quantile_over_time(0.9, ((container_memory_working_set_bytes{id="/"} * on(node) group_left() group by (node) (kube_node_role{role="master"})))[${d_all}:1s] )), "quantile", "0.9", "", "")
${t_all}     cluster:usage:mem:working_set:control_plane:quantile label_replace(max(quantile_over_time(0.5, ((container_memory_working_set_bytes{id="/"} * on(node) group_left() group by (node) (kube_node_role{role="master"})))[${d_all}:1s] )), "quantile", "0.5", "", "")

${t_all}     cluster:alerts:total:firing:distinct:severity count by (severity) (count by (alertname,severity) (count_over_time(ALERTS{alertstate="firing",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}[${d_all}])))

${t_test}    cluster:alerts:total:firing:seconds:severity count_over_time((sum by (severity) (count by (alertname,severity) (ALERTS{alertstate="firing",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}))[${d_test}:1s]))
${t_install} cluster:alerts:install:firing:seconds:severity count_over_time((sum by (severity) (count by (alertname,severity) (ALERTS{alertstate="firing",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}))[${d_install}:1s]))
${t_test}    cluster:alerts:test:firing:seconds:severity count_over_time((sum by (severity) (count by (alertname,severity) (ALERTS{alertstate="firing",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}))[${d_test}:1s]))

${t_test}    cluster:alerts:total:pending:seconds:severity count_over_time((sum by (severity) (count by (alertname,severity) (ALERTS{alertstate="pending",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}))[${d_test}:1s]))
${t_install} cluster:alerts:install:pending:seconds:severity count_over_time((sum by (severity) (count by (alertname,severity) (ALERTS{alertstate="pending",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}))[${d_install}:1s]))
${t_test}    cluster:alerts:test:pending:seconds:severity count_over_time((sum by (severity) (count by (alertname,severity) (ALERTS{alertstate="pending",alertname!~"AlertmanagerReceiversNotConfigured|Watchdog"}))[${d_test}:1s]))

${t_all}     cluster:api:total:requests sum(increase(apiserver_request_total[${d_all}]))
${t_install} cluster:api:install:requests sum(increase(apiserver_request_total[${d_install}]))
${t_test}    cluster:api:requests:test sum(increase(apiserver_request_total[${d_test}]))

${t_all}     cluster:api:read:total:requests sum(increase(apiserver_request_total{verb=~"GET|LIST|WATCH"}[${d_all}]))
${t_install} cluster:api:read:install:requests sum(increase(apiserver_request_total{verb=~"GET|LIST|WATCH"}[${d_install}]))
${t_test}    cluster:api:read:test:requests sum(increase(apiserver_request_total{verb=~"GET|LIST|WATCH"}[${d_test}]))
${t_all}     cluster:api:write:total:requests sum(increase(apiserver_request_total{verb!~"GET|LIST|WATCH"}[${d_all}]))
${t_install} cluster:api:write:install:requests sum(increase(apiserver_request_total{verb!~"GET|LIST|WATCH"}[${d_install}]))
${t_test}    cluster:api:write:test:requests sum(increase(apiserver_request_total{verb!~"GET|LIST|WATCH"}[${d_test}]))

${t_all}     cluster:api:errors:total:requests sum(increase(apiserver_request_total{code=~"5\\\\d\\\\d|0"}[${d_all}]))
${t_install} cluster:api:errors:install:requests sum(increase(apiserver_request_total{code=~"5\\\\d\\\\d|0"}[${d_install}]))

${t_install} cluster:resource:install:count sort_desc(max by(resource) (etcd_object_counts)) > 1
${t_test}    cluster:resource:test:delta sort_desc(max by(resource) (delta(etcd_object_counts[${d_test}]))) != 0

${t_all}     cluster:node:total:boots sum(increase(node_boots_total[${d_all}]))
${t_test}    cluster:node:test:boots sum(increase(node_boots_total[${d_test}]))

${t_all}     cluster:pod:openshift:unready:total:fraction   1-max(avg_over_time(cluster:usage:openshift:kube_running_pod_ready:avg[${d_all}]))
${t_install} cluster:pod:openshift:unready:install:fraction 1-max(avg_over_time(cluster:usage:openshift:kube_running_pod_ready:avg[${d_install}]))
${t_test}    cluster:pod:openshift:unready:test:fraction    1-max(avg_over_time(cluster:usage:openshift:kube_running_pod_ready:avg[${d_test}]))

${t_all}     cluster:pod:openshift:started:total:count sum(changes(kube_pod_start_time{namespace=~"openshift-.*"}[${d_all}]) + 1)
${t_install} cluster:pod:openshift:started:install:count sum(changes(kube_pod_start_time{namespace=~"openshift-.*"}[${d_install}]) + 1)
${t_test}    cluster:pod:openshift:started:test:count sum(changes(kube_pod_start_time{namespace=~"openshift-.*"}[${d_test}]))

${t_all}     cluster:container:total:started count(count_over_time((count without(container,endpoint,name,namespace,pod,service,job,metrics_path,instance,image) (container_start_time_seconds{container!="",container!="POD",pod!=""}))[${d_all}:30s]))
${t_install} cluster:container:install:started  count(count_over_time((count without(container,endpoint,name,namespace,pod,service,job,metrics_path,instance,image) (container_start_time_seconds{container!="",container!="POD",pod!=""}))[${d_install}:30s]))
${t_test}    cluster:container:test:started  count(count_over_time((count without(container,endpoint,name,namespace,pod,service,job,metrics_path,instance,image) (container_start_time_seconds{container!="",container!="POD",pod!=""} > (${t_test}-${s_test})))[${d_test}:30s]))

${t_all}     cluster:version:info:total   topk(1, max by (version) (max_over_time(cluster_version{type="completed"}[${d_all}])))*0+1
${t_install} cluster:version:info:install topk(1, max by (version) (max_over_time(cluster_version{type="completed"}[${d_install}])))*0+1

${t_all}     cluster:version:current:seconds count_over_time(max by (version) ((cluster_version{type="current"}))[${d_all}:1s])
${t_test}    cluster:version:updates:seconds count_over_time(max by (version) ((cluster_version{type="updating",from_version!=""}))[${d_test}:1s])

${t_all}     job:duration:total:seconds vector(${s_all})
${t_install} job:duration:install:seconds vector(${s_install})
${t_test}    job:duration:test:seconds vector(${s_test})
END

# topk(1, max by (image, version) (max_over_time(cluster_version{type="completed"}[30m])))

# Perform variable replacement by putting each line of the query file through an eval and then outputting
# it back to a file.
# glob expansion is disabled because we use '*' in queries for multiplication
set -f
# clear the file
echo > /tmp/queries_resolved
while IFS= read -r i; do
  if [[ -z "${i}" ]]; then continue; fi
  # Try to convert the line of the file into a query, performing bash substitution AND catch undefined variables
  # The heredoc is necessary because bash will perform quote evaluation on labels in queries (pod="x" becomes pod=x)
  if ! q=$( eval $'cat <<END\n'$i$'\nEND\n' 2>/dev/null ); then
    # evaluate the errors and output them to stderr
    (
      set +e
      set +x
      q=$( eval $'cat <<END\n'$i$'\nEND\n' 2>&1 1>/dev/null )
      echo "error: Query '${i}' was not valid:$(echo "${q}" | cut -f 3- -d ':')" 1>&2
    )
    continue
  fi
  echo "${q}" >> /tmp/queries_resolved
done < /tmp/queries
set +f

# Output the script to execute. The first part embeds the evaluated queries and will write them to /tmp
# on the remote system.
cat <<SCRIPT
#!/bin/bash
set -euo pipefail

cat > /tmp/queries <<'END'
$( cat /tmp/queries_resolved )
END
SCRIPT
# The second part of the script iterates over the evaluated queries and queries a local prometheus.
# Variables are not expanded in this section.
cat <<'SCRIPT'
while IFS= read -r q; do
  if [[ -z "${q}" ]]; then continue; fi
  # part up the line '<unix_timestamp_query_time> <name> <query>'
  timestamp=${q%% *}
  q=${q#* }
  name=${q%% *}
  query="${q#* }"
  # perform the query against the local prometheus instance
  if ! out=$( curl -f --silent http://localhost:9090/api/v1/query --data-urlencode "time=${timestamp}" --data-urlencode "query=${query}" ); then
    echo "error: Query ${name} failed at ${timestamp}: ${query}" 1>&2
    continue
  fi
  # wrap the
  echo "{\"${name}\":${out}}"
done < /tmp/queries
SCRIPT
GENERATE
script="$(
  TEST_TIME_INSTALL_START="$( cat ${SHARED_DIR}/TEST_TIME_INSTALL_START || true )" \
  TEST_TIME_INSTALL_END="$( cat ${SHARED_DIR}/TEST_TIME_INSTALL_END || true  )" \
  TEST_TIME_TEST_START="$( cat ${SHARED_DIR}/TEST_TIME_TEST_START || true  )" \
  TEST_TIME_TEST_END="$( cat ${SHARED_DIR}/TEST_TIME_TEST_END || true  )" \
  bash /tmp/generate.sh
)"
queue ${ARTIFACT_DIR}/metrics/job_metrics.json oc --insecure-skip-tls-verify rsh -T -n openshift-monitoring -c thanos-query deploy/thanos-querier /bin/bash -c "${script}"

wait

# This is a temporary conversion of cluster operator status to JSON matching the upgrade - may be moved to code in the future
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 >/tmp/jq && chmod ug+x /tmp/jq
mkdir -p ${ARTIFACT_DIR}/junit/
<${ARTIFACT_DIR}/clusteroperators.json /tmp/jq -r 'def one(condition; t): t as $t | first([.[] | select(condition)] | map(.type=t)[]) // null; def msg: "Operator \(.type) (\(.reason)): \(.message)"; def xmlfailure: if .failure then "<failure message=\"\(.failure | @html)\">\(.failure | @html)</failure>" else "" end; def xmltest: "<testcase name=\"\(.name | @html)\">\( xmlfailure )</testcase>"; def withconditions: map({name: "operator conditions \(.metadata.name)"} + ((.status.conditions // [{type:"Available",status: "False",message:"operator is not reporting conditions"}]) | (one(.type=="Available" and .status!="True"; "unavailable") // one(.type=="Degraded" and .status=="True"; "degraded") // one(.type=="Progressing" and .status=="True"; "progressing") // null) | if . then {failure: .|msg} else null end)); .items | withconditions | "<testsuite name=\"Operator results\" tests=\"\( length )\" failures=\"\( [.[] | select(.failure)] | length )\">\n\( [.[] | xmltest] | join("\n"))\n</testsuite>"' >${ARTIFACT_DIR}/junit/junit_install_status.xml

# This is an experimental wiring of autogenerated failure detection.
echo "Detect known failures from symptoms (experimental) ..."
curl -f https://gist.githubusercontent.com/smarterclayton/03b50c8f9b6351b2d9903d7fb35b342f/raw/symptom.sh 2>/dev/null | bash -s ${ARTIFACT_DIR} > ${ARTIFACT_DIR}/junit/junit_symptoms.xml
