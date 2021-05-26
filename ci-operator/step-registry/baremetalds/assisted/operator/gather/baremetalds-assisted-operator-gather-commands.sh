#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator gather command ************"

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
# shellcheck disable=SC2087
timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeo pipefail

# Get sosreport including sar data
sosreport --ticket-number "\${HOSTNAME}" --batch -o container_log,filesys,kvm,libvirt,logs,networkmanager,podman,processor,rpm,sar,virsh,yum --tmp-dir /tmp/artifacts
cp -R ./reports /tmp/artifacts || true

# Get assisted logs
export LOGS_DEST=/tmp/artifacts

oc cluster-info > \${LOGS_DEST}/k8s_cluster_info.log
oc get all -n assisted-installer > \${LOGS_DEST}/k8s_get_all.log || true

oc logs -n assisted-installer --selector app=assisted-service -c assisted-service > \${LOGS_DEST}/assisted-service.log
oc logs -n assisted-installer --selector app=assisted-service -c postgres > \${LOGS_DEST}/postgres.log
oc logs -n assisted-installer --selector control-plane=assisted-service-operator > \${LOGS_DEST}/assisted-service-operator.log

oc get events -n assisted-installer --sort-by=.metadata.creationTimestamp > \${LOGS_DEST}/k8s_events.log || true

EOF
