#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted gather command ************"

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
timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

cd /home/assisted

source /root/config

# Get sosreport including sar data
sos report --batch --tmp-dir /tmp/artifacts \
  -o container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,yum \
  -k podman.all -k podman.logs

# TODO: remove when https://github.com/sosreport/sos/pull/2594 is available
cp -r /var/lib/libvirt/dnsmasq /tmp/artifacts/libvirt-dnsmasq

cp -R ./reports /tmp/artifacts || true
find -name '*.log' -exec cp -v {} /tmp/artifacts \; || true

# Get assisted logs
export LOGS_DEST=/tmp/artifacts
export KUBECTL="kubectl --kubeconfig=\${HOME}/.kube/config"

make download_service_logs

export ADDITIONAL_PARAMS=""
if [ "${SOSREPORT}" == "true" ]; then
  ADDITIONAL_PARAMS="\${ADDITIONAL_PARAMS} --sosreport"
fi
if [ "${MUST_GATHER}" == "true" ]; then
  ADDITIONAL_PARAMS="\${ADDITIONAL_PARAMS} --must-gather"
fi
if [ "${GATHER_ALL_CLUSTERS}" == "true" ]; then
  ADDITIONAL_PARAMS="\${ADDITIONAL_PARAMS} --download-all"
fi
make download_cluster_logs

for kubeconfig in \$(find \${KUBECONFIG} -type f); do
  export KUBECTL="kubectl --kubeconfig=\${kubeconfig}"
  name=\$(basename \${kubeconfig})
  export LOGS_DEST=/tmp/artifacts/new_cluster_\${name}
  make download_service_logs
done

EOF
