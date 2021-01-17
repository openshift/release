#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted gather command ************"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [ -x "$(command -v nss_wrapper.pl)" ]; then
        grep -v -e ^default -e ^"$(id -u)" /etc/passwd > "/tmp/passwd"
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> "/tmp/passwd"
        export LD_PRELOAD=libnss_wrapper.so
        export NSS_WRAPPER_PASSWD=/tmp/passwd
        export NSS_WRAPPER_GROUP=/etc/group
    elif [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> "/etc/passwd"
    else
        echo "No nss wrapper, /etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ]; then
  echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
  exit 1
fi

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet server IP
IP=$(cat "${SHARED_DIR}/server-ip")
SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -i "${CLUSTER_PROFILE_DIR}/.packet-kni-ssh-privatekey")

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

NAMESPACE="assisted-installer"

# Print pods
KUBECONFIG=\${HOME}/.kube/config kubectl get pods -n \${NAMESPACE}

# Get pods
if [ "\${DEPLOY_TARGET:-}" = "onprem" ]; then
  for service in "installer" "db"; do
    podman logs \${service}  > /tmp/artifacts/onprem_\${service}.log || true
  done
else
  for service in "assisted-service" "postgres" "scality" "createimage"; do
    KUBECONFIG=\${HOME}/.kube/config kubectl get pods -o=custom-columns=NAME:.metadata.name -A | grep \${service} | xargs -r -I {} sh -c "KUBECONFIG=\${HOME}/.kube/config kubectl logs {} -n \${NAMESPACE} > /tmp/artifacts/k8s_{}.log" || true
  done
fi

# Get assisted logs
if [ "\${DEPLOY_TARGET:-}" = "onprem" ]; then
  make download_all_logs LOGS_DEST=/tmp/artifacts REMOTE_SERVICE_URL=http://localhost:8090
else
  make download_all_logs LOGS_DEST=/tmp/artifacts REMOTE_SERVICE_URL=\$(KUBECONFIG=\${HOME}/.kube/config minikube service assisted-service -n \${NAMESPACE} --url)
fi

EOF
