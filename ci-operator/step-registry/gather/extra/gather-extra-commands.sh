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

export PATH="${PATH}:/tmp/shared"

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering artifacts ..."
mkdir -p "${ARTIFACT_DIR}/pods" "${ARTIFACT_DIR}/nodes" "${ARTIFACT_DIR}/metrics" "${ARTIFACT_DIR}/bootstrap" "${ARTIFACT_DIR}/network" "${ARTIFACT_DIR}/oc_cmds"

oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' > /tmp/nodes
# shellcheck disable=SC2016 # we want the JSONPath $ to pass through to oc.
oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces --template '{{ range .items }}{{ $name := .metadata.name }}{{ $ns := .metadata.namespace }}{{ range .spec.containers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ range .spec.initContainers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ end }}' > /tmp/containers
oc --insecure-skip-tls-verify --request-timeout=5s get pods -l openshift.io/component=api --all-namespaces -o jsonpath='{range .items}-n {.metadata.namespace} {.metadata.name}{"\n"}{end}' > /tmp/pods-api

queue  "${ARTIFACT_DIR}/config-resources.json" oc --insecure-skip-tls-verify --request-timeout=5s get apiserver.config.openshift.io authentication.config.openshift.io build.config.openshift.io console.config.openshift.io dns.config.openshift.io featuregate.config.openshift.io image.config.openshift.io infrastructure.config.openshift.io ingress.config.openshift.io network.config.openshift.io oauth.config.openshift.io project.config.openshift.io scheduler.config.openshift.io -o json
queue  "${ARTIFACT_DIR}/apiservices.json" oc --insecure-skip-tls-verify --request-timeout=5s get apiservices -o json
queue  "${ARTIFACT_DIR}/oc_cmds/apiservices" oc --insecure-skip-tls-verify --request-timeout=5s get apiservices
queue  "${ARTIFACT_DIR}/clusteroperators.json" oc --insecure-skip-tls-verify --request-timeout=5s get clusteroperators -o json
queue  "${ARTIFACT_DIR}/oc_cmds/clusteroperators" oc --insecure-skip-tls-verify --request-timeout=5s get clusteroperators
queue  "${ARTIFACT_DIR}/clusterversion.json" oc --insecure-skip-tls-verify --request-timeout=5s get clusterversion -o json
queue  "${ARTIFACT_DIR}/oc_cmds/clusterversion" oc --insecure-skip-tls-verify --request-timeout=5s get clusterversion
queue  "${ARTIFACT_DIR}/configmaps.json" oc --insecure-skip-tls-verify --request-timeout=5s get configmaps --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/configmaps" oc --insecure-skip-tls-verify --request-timeout=5s get configmaps --all-namespaces
queue  "${ARTIFACT_DIR}/credentialsrequests.json" oc --insecure-skip-tls-verify --request-timeout=5s get credentialsrequests --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/credentialsrequests" oc --insecure-skip-tls-verify --request-timeout=5s get credentialsrequests --all-namespaces
queue  "${ARTIFACT_DIR}/csr.json" oc --insecure-skip-tls-verify --request-timeout=5s get csr -o json
queue  "${ARTIFACT_DIR}/endpoints.json" oc --insecure-skip-tls-verify --request-timeout=5s get endpoints --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/endpoints" oc --insecure-skip-tls-verify --request-timeout=5s get endpoints --all-namespaces
FILTER=gzip queue  "${ARTIFACT_DIR}/deployments.json.gz" oc --insecure-skip-tls-verify --request-timeout=5s get deployments --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/deployments" oc --insecure-skip-tls-verify --request-timeout=5s get deployments --all-namespaces -o wide
FILTER=gzip queue  "${ARTIFACT_DIR}/daemonsets.json.gz" oc --insecure-skip-tls-verify --request-timeout=5s get daemonsets --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/daemonsets" oc --insecure-skip-tls-verify --request-timeout=5s get daemonsets --all-namespaces -o wide
queue  "${ARTIFACT_DIR}/events.json" oc --insecure-skip-tls-verify --request-timeout=5s get events --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/events" oc --insecure-skip-tls-verify --request-timeout=5s get events --all-namespaces
queue  "${ARTIFACT_DIR}/kubeapiserver.json" oc --insecure-skip-tls-verify --request-timeout=5s get kubeapiserver -o json
queue  "${ARTIFACT_DIR}/oc_cmds/kubeapiserver" oc --insecure-skip-tls-verify --request-timeout=5s get kubeapiserver
queue  "${ARTIFACT_DIR}/kubecontrollermanager.json" oc --insecure-skip-tls-verify --request-timeout=5s get kubecontrollermanager -o json
queue  "${ARTIFACT_DIR}/oc_cmds/kubecontrollermanager" oc --insecure-skip-tls-verify --request-timeout=5s get kubecontrollermanager
queue  "${ARTIFACT_DIR}/machineconfigpools.json" oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigpools -o json
queue  "${ARTIFACT_DIR}/oc_cmds/machineconfigpools" oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigpools
queue  "${ARTIFACT_DIR}/machineconfigs.json" oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigs -o json
queue  "${ARTIFACT_DIR}/oc_cmds/machineconfigs" oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigs
queue  "${ARTIFACT_DIR}/machinesets.json" oc --insecure-skip-tls-verify --request-timeout=5s get machinesets -A -o json
queue  "${ARTIFACT_DIR}/oc_cmds/machinesets" oc --insecure-skip-tls-verify --request-timeout=5s get machinesets -A
queue  "${ARTIFACT_DIR}/machines.json" oc --insecure-skip-tls-verify --request-timeout=5s get machines -A -o json
queue  "${ARTIFACT_DIR}/oc_cmds/machines" oc --insecure-skip-tls-verify --request-timeout=5s get machines -A -o wide
queue  "${ARTIFACT_DIR}/namespaces.json" oc --insecure-skip-tls-verify --request-timeout=5s get namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/namespaces" oc --insecure-skip-tls-verify --request-timeout=5s get namespaces
queue  "${ARTIFACT_DIR}/nodes.json" oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o json
queue  "${ARTIFACT_DIR}/oc_cmds/nodes" oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o wide
queue  "${ARTIFACT_DIR}/openshiftapiserver.json" oc --insecure-skip-tls-verify --request-timeout=5s get openshiftapiserver -o json
queue  "${ARTIFACT_DIR}/oc_cmds/openshiftapiserver" oc --insecure-skip-tls-verify --request-timeout=5s get openshiftapiserver
queue  "${ARTIFACT_DIR}/pods.json" oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/pods" oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces -o wide
queue  "${ARTIFACT_DIR}/persistentvolumes.json" oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumes --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/persistentvolumes" oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumes --all-namespaces -o wide
queue  "${ARTIFACT_DIR}/persistentvolumeclaims.json" oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumeclaims --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/persistentvolumeclaims" oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumeclaims --all-namespaces -o wide
FILTER=gzip queue  "${ARTIFACT_DIR}/replicasets.json.gz" oc --insecure-skip-tls-verify --request-timeout=5s get replicasets --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/replicasets" oc --insecure-skip-tls-verify --request-timeout=5s get replicasets --all-namespaces -o wide
queue  "${ARTIFACT_DIR}/rolebindings.json" oc --insecure-skip-tls-verify --request-timeout=5s get rolebindings --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/rolebindings" oc --insecure-skip-tls-verify --request-timeout=5s get rolebindings --all-namespaces
queue  "${ARTIFACT_DIR}/roles.json" oc --insecure-skip-tls-verify --request-timeout=5s get roles --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/roles" oc --insecure-skip-tls-verify --request-timeout=5s get roles --all-namespaces
queue  "${ARTIFACT_DIR}/services.json" oc --insecure-skip-tls-verify --request-timeout=5s get services --all-namespaces -o json
queue  "${ARTIFACT_DIR}/oc_cmds/services" oc --insecure-skip-tls-verify --request-timeout=5s get services --all-namespaces
FILTER=gzip queue  "${ARTIFACT_DIR}/statefulsets.json.gz" oc --insecure-skip-tls-verify --request-timeout=5s get statefulsets --all-namespaces -o json
queue  "${ARTIFACT_DIR}/statefulsets" oc --insecure-skip-tls-verify --request-timeout=5s get statefulsets --all-namespaces

FILTER=gzip queue  "${ARTIFACT_DIR}/openapi.json.gz" oc --insecure-skip-tls-verify --request-timeout=5s get --raw /openapi/v2

# gather nodes first in parallel since they may contain the most relevant debugging info
while IFS= read -r i; do
  mkdir -p  "${ARTIFACT_DIR}/nodes/$i"
  queue  "${ARTIFACT_DIR}/nodes/$i/heap" oc --insecure-skip-tls-verify get --request-timeout=20s --raw "/api/v1/nodes/$i/proxy/debug/pprof/heap"
done < /tmp/nodes

FILTER=gzip queue  "${ARTIFACT_DIR}/nodes/masters-journal.gz" oc --insecure-skip-tls-verify adm node-logs --role=master --unify=false
FILTER=gzip queue  "${ARTIFACT_DIR}/nodes/masters-journal-previous.gz" oc --insecure-skip-tls-verify adm node-logs --boot=-1 --role=master --unify=false
FILTER=gzip queue  "${ARTIFACT_DIR}/nodes/workers-journal.gz" oc --insecure-skip-tls-verify adm node-logs --role=worker --unify=false
FILTER=gzip queue  "${ARTIFACT_DIR}/nodes/workers-journal-previous.gz" oc --insecure-skip-tls-verify adm node-logs --boot=-1 --role=worker --unify=false

# Snapshot iptables-save on each node for debugging possible kube-proxy issues
oc --insecure-skip-tls-verify get --request-timeout=20s -n openshift-sdn -l app=sdn pods --template '{{ range .items }}{{ .metadata.name }}{{ "\n" }}{{ end }}' > /tmp/sdn-pods
while IFS= read -r i; do
  queue  "${ARTIFACT_DIR}/network/iptables-save-$i" oc --insecure-skip-tls-verify rsh --timeout=20 -n openshift-sdn -c sdn "$i" iptables-save -c
done < /tmp/sdn-pods

while IFS= read -r i; do
  file="$( echo "$i" | cut -d ' ' -f 3 | tr -s ' ' '_' )"
  # shellcheck disable=SC2016 # we want the subcommand's $ to pass through to oc.
  queue  "${ARTIFACT_DIR}/metrics/${file}-heap" oc --insecure-skip-tls-verify exec "$i" -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8443" --config /etc/origin/master/admin.kubeconfig'
  # shellcheck disable=SC2016 # we want the subcommand's $ to pass through to oc.
  queue  "${ARTIFACT_DIR}/metrics/${file}-controllers-heap" oc --insecure-skip-tls-verify exec "$i" -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8444" --config /etc/origin/master/admin.kubeconfig'
done < /tmp/pods-api

while IFS= read -r i; do
  file="$( echo "$i" | cut -d ' ' -f 2,3,5 | tr -s ' ' '_' )"
  FILTER=gzip queue  "${ARTIFACT_DIR}/pods/${file}.log.gz" oc --insecure-skip-tls-verify logs --request-timeout=20s "$i"
  FILTER=gzip queue  "${ARTIFACT_DIR}/pods/${file}_previous.log.gz" oc --insecure-skip-tls-verify logs --request-timeout=20s -p "$i"
done < /tmp/containers

echo "Snapshotting prometheus (may take 15s) ..."
queue  "${ARTIFACT_DIR}/metrics/prometheus.tar.gz" oc --insecure-skip-tls-verify exec -n openshift-monitoring prometheus-k8s-0 -- tar cvzf - -C /prometheus .
FILTER=gzip queue  "${ARTIFACT_DIR}/metrics/prometheus-target-metadata.json.gz" oc --insecure-skip-tls-verify exec -n openshift-monitoring prometheus-k8s-0 -- /bin/bash -c "curl -G http://localhost:9090/api/v1/targets/metadata --data-urlencode 'match_target={instance!=\"\"}'"

wait
