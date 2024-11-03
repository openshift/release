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

CLUSTER_AGE_DAYS=${1:-90}
CLUSTER_AGE_STEP=${2:-30}

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  for kubeconfig in $(find ${KUBECONFIG} -type f); do
    export KUBECONFIG=${kubeconfig}
  done
fi

source /usr/local/share/cert-rotation-functions.sh

export KUBECONFIG_NODE_DIR="/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs"

# Stop chrony service on all nodes
run-on-all-nodes "systemctl disable chronyd --now"

function emulate-cluster-age {
  # Set date for host
  sudo timedatectl set-time +${1}d

  # Skew clock on every node
  run-on-all-nodes "timedatectl set-time +${1}d"

  # Restart kubelet
  run-on-all-nodes "systemctl restart kubelet"

  pod-restart-workarounds

  # Wait for nodes to become unready and approve CSRs until nodes are ready again
  wait-for-nodes-to-be-ready

  wait-for-operators-to-stabilize

  oc --request-timeout=5s get nodes
}

full_steps=$((${CLUSTER_AGE_DAYS}/${CLUSTER_AGE_STEP}))
modulo=$((${CLUSTER_AGE_DAYS}%${CLUSTER_AGE_STEP}))

if [[ ${full_steps} -gt 0 ]]; then
  for i in $(seq 1 ${full_steps}); do
    emulate-cluster-age ${CLUSTER_AGE_STEP}
  done
fi
if [[ ${modulo} -gt 0 ]]; then
  emulate-cluster-age ${modulo}
fi
exit 0

EOF
chmod +x "${SHARED_DIR}"/cluster-age-test.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/cluster-age-test.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	8h \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/cluster-age-test.sh \
	${CLUSTER_AGE_DAYS} \
  ${CLUSTER_AGE_STEP}
