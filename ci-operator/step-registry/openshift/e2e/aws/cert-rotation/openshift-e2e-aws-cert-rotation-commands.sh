#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation suspend test command ************"
# This file is scp'd to the bastion host
# It stops kubelet service, disables chronyd service on each node and
# sets date ahead on SKEW time (default: 90 days)
# then starts kubelet on each node and waits for cluster recovery.
# This simulates cert-rotation after specified period
# TODO: Run suite of conformance tests after recovery
cat <<'EOF' > /tmp/time-skew.sh
#!/bin/bash
export KUBECONFIG="/tmp/kubeconfig"

set -euxo pipefail
SKEW=${1:-30d}
OC=${OC:-oc}
SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SSH=${SSH:-ssh ${SSH_OPTS}}
SCP=${SCP:-scp ${SSH_OPTS}}
COMMAND_TIMEOUT=60m

mapfile -d ' ' -t control_nodes < <( ${OC} get nodes --selector='node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

mapfile -d ' ' -t compute_nodes < <( ${OC} get nodes --selector='!node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

function run-on-all-nodes {
  for n in ${control_nodes[@]} ${compute_nodes[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-workers {
  for n in ${compute_nodes[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuxo pipefail' <<< ${1}
}

function copy-file-from-first-master {
  timeout ${COMMAND_TIMEOUT} ${SCP} "core@${control_nodes[0]}:${1}" "${2}"
}

echo "control nodes: ${control_nodes[@]}"
echo "compute nodes: ${compute_nodes[@]}"

ssh-keyscan -H ${control_nodes[@]} ${compute_nodes[@]} >> ~/.ssh/known_hosts

# Stop chrony service on all nodes
run-on-all-nodes "systemctl disable chronyd --now"

# Backup lb-ext kubeconfig so that it could be compared to a new one
export KUBECONFIG_NODE_DIR="/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs"
KUBECONFIG_LB_EXT="${KUBECONFIG_NODE_DIR}/lb-ext.kubeconfig"
KUBECONFIG_LOCAL="/tmp/lb-ext.kubeconfig"
run-on-first-master "cp ${KUBECONFIG_LB_EXT} ${KUBECONFIG_LOCAL} && chmod 0666 ${KUBECONFIG_LOCAL}"
copy-file-from-first-master "${KUBECONFIG_LOCAL}" "${KUBECONFIG_LOCAL}"

# Skew clock on every node
# TODO: Suspend, resume and make it resync time from host instead?
run-on-all-nodes "
  timedatectl status
  timedatectl set-time +${SKEW}
  timedatectl status
"

# Wait for nodes to become unready
run-on-first-master "
  export KUBECONFIG=${KUBECONFIG_NODE_DIR}/localhost-recovery.kubeconfig
  until oc get nodes; do sleep 30; done
  sleep 5m
"

# Restart kubelets on workers
run-on-workers "systemctl restart kubelet"

# Approve CSRs until nodes are ready again
run-on-first-master "
  export KUBECONFIG=${KUBECONFIG_NODE_DIR}/localhost-recovery.kubeconfig
  until oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s; do
    oc get nodes
    if ! oc wait csr --all --for condition=Approved=True --timeout=30s; then
      oc get csr | grep Pending | cut -f1 -d' ' | xargs oc adm certificate approve || true
    fi
    sleep 30
  done
  oc get nodes
"

# Pod restart workarounds
run-on-first-master "
  export KUBECONFIG=${KUBECONFIG_NODE_DIR}/localhost-recovery.kubeconfig
  # Workaround for https://issues.redhat.com/browse/OCPBUGS-42001
  # Restart Multus before proceeding
  oc --request-timeout=5s -n openshift-multus delete pod -l app=multus --force --grace-period=0
"

# Wait for operators to stabilize
run-on-first-master "
  export KUBECONFIG=${KUBECONFIG_NODE_DIR}/localhost-recovery.kubeconfig
  if ! oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=60m; then
    oc get nodes
    oc get co | grep -v "True\s\+False\s\+False"
    exit 1
  else
    oc get nodes
    oc get co
    oc get clusterversion
  fi
"
exit 0
EOF

BASTION_USER="$(cat ${SHARED_DIR}/bastion_ssh_user)"
BASTION_HOST="$(cat ${SHARED_DIR}/bastion_public_address)"

SSH_OPTS="-o ConnectionAttempts=200 -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR -i ${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH="ssh ${SSH_OPTS} ${BASTION_USER}@${BASTION_HOST}"
SCP="scp ${SSH_OPTS}"

# configure the local container environment to have the correct SSH configuration
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

# Wait for bastion to become available
until ${SSH} "id"; do sleep 30; done

# Copy ssh private key
${SCP} "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${BASTION_USER}@${BASTION_HOST}:/tmp/id_rsa"
${SSH} "sudo mkdir /root/.ssh -p && sudo mv /tmp/id_rsa /root/.ssh/id_rsa && sudo chmod 0600 /root/.ssh/id_rsa"

# Install oc
${SSH} "curl -L https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz -o oc.tar.gz && tar xzvf oc.tar.gz && sudo mv oc /usr/local/bin/"

# Copy timeskew script
${SCP} "/tmp/time-skew.sh" "${BASTION_USER}@${BASTION_HOST}:/tmp/timeskew.sh"
${SSH} "sudo mv /tmp/timeskew.sh /usr/local/bin/timeskew.sh && sudo chmod 0755 /usr/local/bin/timeskew.sh"

# Copy kubeconfig
${SCP} "${SHARED_DIR}/kubeconfig" "${BASTION_USER}@${BASTION_HOST}:/tmp/kubeconfig"

# Run the time skew script
${SSH} "sudo /bin/bash /usr/local/bin/timeskew.sh"
