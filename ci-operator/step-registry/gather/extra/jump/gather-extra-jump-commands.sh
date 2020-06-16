#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

# This must match exactly to the gather-extra-commands.sh
cat >> ${WORKSPACE}/gather-extra-commands.sh << 'EOF'
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

export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export PATH=${PATH}:${WORKSPACE}

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering artifacts ..."
mkdir -p ${ARTIFACT_DIR}/pods ${ARTIFACT_DIR}/nodes ${ARTIFACT_DIR}/metrics ${ARTIFACT_DIR}/bootstrap ${ARTIFACT_DIR}/network ${ARTIFACT_DIR}/oc_cmds

oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' > ${WORKSPACE}/nodes
oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' > ${WORKSPACE}/node-provider-IDs
oc --insecure-skip-tls-verify --request-timeout=5s -n openshift-machine-api get machines -o jsonpath --template '{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' >> ${WORKSPACE}/node-provider-IDs
oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces --template '{{ range .items }}{{ $name := .metadata.name }}{{ $ns := .metadata.namespace }}{{ range .spec.containers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ range .spec.initContainers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ end }}' > ${WORKSPACE}/containers
oc --insecure-skip-tls-verify --request-timeout=5s get pods -l openshift.io/component=api --all-namespaces --template '{{ range .items }}-n {{ .metadata.namespace }} {{ .metadata.name }}{{ "\n" }}{{ end }}' > ${WORKSPACE}/pods-api

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
done < ${WORKSPACE}/nodes

FILTER=gzip queue ${ARTIFACT_DIR}/nodes/masters-journal.gz oc --insecure-skip-tls-verify adm node-logs --role=master --unify=false
FILTER=gzip queue ${ARTIFACT_DIR}/nodes/masters-journal-previous.gz oc --insecure-skip-tls-verify adm node-logs --boot=-1 --role=master --unify=false
FILTER=gzip queue ${ARTIFACT_DIR}/nodes/workers-journal.gz oc --insecure-skip-tls-verify adm node-logs --role=worker --unify=false
FILTER=gzip queue ${ARTIFACT_DIR}/nodes/workers-journal-previous.gz oc --insecure-skip-tls-verify adm node-logs --boot=-1 --role=worker --unify=false

# Snapshot iptables-save on each node for debugging possible kube-proxy issues
oc --insecure-skip-tls-verify get --request-timeout=20s -n openshift-sdn -l app=sdn pods --template '{{ range .items }}{{ .metadata.name }}{{ "\n" }}{{ end }}' > ${WORKSPACE}/sdn-pods
while IFS= read -r i; do
  queue ${ARTIFACT_DIR}/network/iptables-save-$i oc --insecure-skip-tls-verify rsh --timeout=20 -n openshift-sdn -c sdn $i iptables-save -c
done < ${WORKSPACE}/sdn-pods

while IFS= read -r i; do
  file="$( echo "$i" | cut -d ' ' -f 3 | tr -s ' ' '_' )"
  queue ${ARTIFACT_DIR}/metrics/${file}-heap oc --insecure-skip-tls-verify exec $i -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8443" --config /etc/origin/master/admin.kubeconfig'
  queue ${ARTIFACT_DIR}/metrics/${file}-controllers-heap oc --insecure-skip-tls-verify exec $i -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8444" --config /etc/origin/master/admin.kubeconfig'
done < ${WORKSPACE}/pods-api

while IFS= read -r i; do
  file="$( echo "$i" | cut -d ' ' -f 2,3,5 | tr -s ' ' '_' )"
  FILTER=gzip queue ${ARTIFACT_DIR}/pods/${file}.log.gz oc --insecure-skip-tls-verify logs --request-timeout=20s $i
  FILTER=gzip queue ${ARTIFACT_DIR}/pods/${file}_previous.log.gz oc --insecure-skip-tls-verify logs --request-timeout=20s -p $i
done < ${WORKSPACE}/containers

echo "Snapshotting prometheus (may take 15s) ..."
queue ${ARTIFACT_DIR}/metrics/prometheus.tar.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring prometheus-k8s-0 -- tar cvzf - -C /prometheus .
FILTER=gzip queue ${ARTIFACT_DIR}/metrics/prometheus-target-metadata.json.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring prometheus-k8s-0 -- /bin/bash -c "curl -G http://localhost:9090/api/v1/targets/metadata --data-urlencode 'match_target={instance!=\"\"}'"

wait


EOF

run_rsync() {
  set -x
  rsync -PazcOq -e "ssh -q -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i ${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}

run_ssh() {
  set -x
  ssh -q -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i "${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}


REMOTE=$(<"${SHARED_DIR}/jump-host.txt") && export REMOTE
REMOTE_DIR="/tmp/install-$(date +%s%N)" && export REMOTE_DIR

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

run_ssh "${REMOTE}" -- mkdir -p "${REMOTE_DIR}/cluster_profile" "${REMOTE_DIR}/shared_dir" "${REMOTE_DIR}/artifacts_dir"
cat >> ${WORKSPACE}/runner.env << EOF
export RELEASE_IMAGE_LATEST="${RELEASE_IMAGE_LATEST}"

export CLUSTER_TYPE="${CLUSTER_TYPE}"
export CLUSTER_PROFILE_DIR="${REMOTE_DIR}/cluster_profile"
export ARTIFACT_DIR="${REMOTE_DIR}/artifacts_dir"
export SHARED_DIR="${REMOTE_DIR}/shared_dir"
export KUBECONFIG="${REMOTE_DIR}/shared_dir/kubeconfig"

export JOB_NAME="${JOB_NAME}"
export BUILD_ID="${BUILD_ID}"

export WORKSPACE=${REMOTE_DIR}
EOF

run_rsync "$(which oc)" ${WORKSPACE}/runner.env ${WORKSPACE}/gather-extra-commands.sh "${REMOTE}:${REMOTE_DIR}/"
run_rsync "${SHARED_DIR}/" "${REMOTE}:${REMOTE_DIR}/shared_dir/"
run_rsync "${CLUSTER_PROFILE_DIR}/" "${REMOTE}:${REMOTE_DIR}/cluster_profile/"

run_ssh "${REMOTE}" "source ${REMOTE_DIR}/runner.env && bash ${REMOTE_DIR}/gather-extra-commands.sh" &

set +e
wait "$!"
ret="$?"
set -e

run_rsync "${REMOTE}:${REMOTE_DIR}/shared_dir/" "${SHARED_DIR}/"
run_rsync --no-perms "${REMOTE}:${REMOTE_DIR}/artifacts_dir/" "${ARTIFACT_DIR}/"
run_ssh "${REMOTE}" "rm -rf ${REMOTE_DIR}"
exit "$ret"
