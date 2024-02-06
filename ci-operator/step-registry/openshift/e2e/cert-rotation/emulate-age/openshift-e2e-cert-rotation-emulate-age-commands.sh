#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation age emulate command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

if [ "${CLUSTER_AGE_DAYS}" == "0" ]; then
  exit 0
fi

# TODO: Run suite of conformance tests after recovery
cat >"${SHARED_DIR}"/cluster-age-test.sh <<'EOF'
#!/bin/bash

set -euxo pipefail
sudo systemctl stop chronyd

OC=${OC:-oc}
CLUSTER_AGE_DAYS=${1:-30}
SKEW_STEP=30
SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SCP=${SCP:-scp ${SSH_OPTS}}
SSH=${SSH:-ssh ${SSH_OPTS}}
SETTLE_TIMEOUT=5m
COMMAND_TIMEOUT=15m

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  for kubeconfig in $(find ${KUBECONFIG} -type f); do
    export KUBECONFIG=${kubeconfig}
  done
fi

export KUBECONFIG_NODE_DIR="/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs"

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

# Stop chrony service on all nodes
run-on-all-nodes "systemctl disable chronyd --now"

for i in $(seq $((${CLUSTER_AGE_DAYS}/${SKEW_STEP}))); do
  # Set date for host
  sudo timedatectl status
  sudo timedatectl set-time +${SKEW_STEP}d
  sudo timedatectl status

  # Skew clock on every node
  run-on-all-nodes "timedatectl set-time +${SKEW_STEP}d && timedatectl status"

  # Restart kubelet
  run-on-all-nodes "systemctl restart kubelet"

  # Wait for nodes to become unready and approve CSRs until nodes are ready again
  run-on-first-master "
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
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

  # Workaround for https://issues.redhat.com/browse/OCPBUGS-28735
  # Restart OVN / Multus before proceeding
  oc -n openshift-multus delete pod -l app=multus
  oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node
  oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-control-plane

  # Wait for operators to stabilize
  if
    ! oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m; then
      oc get nodes
      oc get co | grep -v "True\s\+False\s\+False"
      exit 1
  fi
done
exit 0

EOF
chmod +x "${SHARED_DIR}"/cluster-age-test.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/cluster-age-test.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/cluster-age-test.sh \
	${CLUSTER_AGE_DAYS}
