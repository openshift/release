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
sosreport --ticket-number "\${HOSTNAME}" --batch -o container_log,filesys,kvm,libvirt,logs,networkmanager,podman,processor,rpm,sar,virsh,yum --tmp-dir /tmp/artifacts

# Get assisted logs
NAMESPACE="assisted-installer"

if [ "\${DEPLOY_TARGET:-}" = "onprem" ]; then
  podman ps -a || true

  for service in "installer" "db"; do
    podman logs \${service}  > /tmp/artifacts/onprem_\${service}.log || true
  done

  make download_all_logs LOGS_DEST=/tmp/artifacts REMOTE_SERVICE_URL=http://localhost:8090
else
  KUBECONFIG=\${HOME}/.kube/config kubectl get pods -n \${NAMESPACE} || true

  for service in "assisted-service" "postgres" "scality" "createimage"; do
    KUBECONFIG=\${HOME}/.kube/config kubectl get pods -o=custom-columns=NAME:.metadata.name -A | grep \${service} | xargs -r -I {} sh -c "KUBECONFIG=\${HOME}/.kube/config kubectl logs {} -n \${NAMESPACE} > /tmp/artifacts/k8s_{}.log" || true
  done

  make download_all_logs LOGS_DEST=/tmp/artifacts REMOTE_SERVICE_URL=\$(KUBECONFIG=\${HOME}/.kube/config minikube service assisted-service -n \${NAMESPACE} --url)
fi

EOF
