#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation shutdown test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# This file is scp'd to the machine where the nested libvirt cluster is running
# It stops kubelet service, kills all containers on each node, kills all pods,
# disables chronyd service on each node and on the machine itself, sets date ahead 400days
# then starts kubelet on each node and waits for cluster recovery. This simulates
# cert-rotation after 1 year.
# TODO: Run suite of conformance tests after recovery
cat >"${SHARED_DIR}"/time-skew-test.sh <<'EOF'
#!/bin/bash

set -euxo pipefail
sudo systemctl stop chronyd

SKEW=${1:-+90d}
OC=${OC:-oc}
SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SCP=${SCP:-scp ${SSH_OPTS}}
SSH=${SSH:-ssh ${SSH_OPTS}}
COMMAND_TIMEOUT=15m

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  for kubeconfig in $(find ${KUBECONFIG} -type f); do
    export KUBECONFIG=${kubeconfig}
  done
fi

mapfile -d ' ' -t control_nodes < <( ${OC} get nodes --selector='node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

mapfile -d ' ' -t compute_nodes < <( ${OC} get nodes --selector='!node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

function run-on-all-nodes {
  for n in ${control_nodes[@]} ${compute_nodes[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuxo pipefail' <<< ${1}
}

function copy-file-from-first-master {
  timeout ${COMMAND_TIMEOUT} ${SCP} "core@${control_nodes[0]}:${1}" "${2}"
}

ssh-keyscan -H ${control_nodes[@]} ${compute_nodes[@]} >> ~/.ssh/known_hosts

# Save found node IPs for "gather-cert-rotation" step
echo -n "${control_nodes[@]}" > /srv/control_node_ips
echo -n "${compute_nodes[@]}" > /srv/compute_node_ips

echo "Wrote control_node_ips: $(cat /srv/control_node_ips), compute_node_ips: $(cat /srv/compute_node_ips)"

# Prepull tools image on the nodes. "gather-cert-rotation" step uses it to run sos report
# However, if time is too far in the future the pull will fail with "Trying to pull registry.redhat.io/rhel8/support-tools:latest...
# Error: initializing source ...: tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time ... is after <now + 6m>"
run-on-all-nodes "podman pull --authfile /var/lib/kubelet/config.json registry.redhat.io/rhel8/support-tools:latest"

# Disable telemeter - its unable to upload snapshots due to significant time skews
run-on-first-master "
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig
  echo "telemeterClient:" > /tmp/config.yaml
  echo "  enabled: false" >> /tmp/config.yaml
  oc create configmap cluster-monitoring-config -n openshift-monitoring --from-file=config.yaml=/tmp/config.yaml
"

# Stop chrony service on all nodes
run-on-all-nodes "systemctl disable chronyd --now"

# Backup lb-ext kubeconfig so that it could be compared to a new one
KUBECONFIG_NODE_DIR="/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs"
KUBECONFIG_LB_EXT="${KUBECONFIG_NODE_DIR}/lb-ext.kubeconfig"
KUBECONFIG_REMOTE="/tmp/lb-ext.kubeconfig"
run-on-first-master "cp ${KUBECONFIG_LB_EXT} ${KUBECONFIG_REMOTE} && chown core:core ${KUBECONFIG_REMOTE}"
copy-file-from-first-master "${KUBECONFIG_REMOTE}" "${KUBECONFIG_REMOTE}"

# Set kubelet node IP hint. Nodes are created with two interfaces - provisioning and external,
# and we want to make sure kubelet uses external address as main, instead of DHCP racing to use 
# a random one as primary
run-on-all-nodes "echo 'KUBELET_NODEIP_HINT=192.168.127.1' | sudo tee /etc/default/nodeip-configuration"

# Shutdown nodes
mapfile -d ' ' -t VMS < <( virsh list --all --name )
for vm in ${VMS[@]}; do
  virsh shutdown ${vm}
  until virsh domstate ${vm} | grep "shut off"; do
    echo "${vm} still running"
    sleep 10
  done
done

# Set date for host
sudo timedatectl status
sudo timedatectl set-time ${SKEW}
sudo timedatectl status

# Start nodes again
for vm in ${VMS[@]}; do
  virsh start ${vm}
  until virsh domstate ${vm} | grep "running"; do
    echo "${vm} still not yet running"
    sleep 10
  done
done

# Check that time on nodes has been updated
until run-on-all-nodes "timedatectl status"; do sleep 30; done

# Wait for nodes to become unready and approve CSRs until nodes are ready again
run-on-first-master "
  export KUBECONFIG=${KUBECONFIG_NODE_DIR}/localhost-recovery.kubeconfig
  until oc get nodes; do sleep 30; done
  sleep 5m
  until oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s; do
    oc get nodes
    if ! oc wait csr --all --for condition=Approved=True --timeout=30s; then
      oc get csr | grep Pending | cut -f1 -d' ' | xargs oc adm certificate approve || true
    fi
    sleep 30
  done
  oc get nodes
  "

# Wait for kube-apiserver operator to generate new localhost-recovery kubeconfig
run-on-first-master "while diff -q ${KUBECONFIG_LB_EXT} ${KUBECONFIG_REMOTE}; do sleep 30; done"

# Copy system:admin's lb-ext kubeconfig locally and use it to access the cluster
run-on-first-master "cp ${KUBECONFIG_LB_EXT} ${KUBECONFIG_REMOTE} && chown core:core ${KUBECONFIG_REMOTE}"
copy-file-from-first-master "${KUBECONFIG_REMOTE}" "${KUBECONFIG_REMOTE}"

# Approve certificates for workers, so that all operators would complete
run-on-first-master "
  export KUBECONFIG=${KUBECONFIG_NODE_DIR}/localhost-recovery.kubeconfig
  until oc wait node --selector='node-role.kubernetes.io/worker' --for condition=Ready --timeout=30s; do
    oc get nodes
    if ! oc wait csr --all --for condition=Approved=True --timeout=30s; then
      oc get csr | grep Pending | cut -f1 -d' ' | xargs oc adm certificate approve || true
    fi
    sleep 30
  done
"

# Wait for operators to stabilize
if
  ! oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m; then
    oc get nodes
    oc get co | grep -v "True\s\+False\s\+False"
    exit 1
else
  oc get nodes
  oc get co
  oc get clusterversion
fi
exit 0

EOF
chmod +x "${SHARED_DIR}"/time-skew-test.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/time-skew-test.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/time-skew-test.sh \
	${SKEW}
