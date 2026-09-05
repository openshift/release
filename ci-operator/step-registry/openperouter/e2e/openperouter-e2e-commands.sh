#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter deploy-verify test ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Cloning OpenPERouter E2E source to remote host"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${OPENPEROUTER_REPO}" "${OPENPEROUTER_BRANCH}" << 'EOFSOURCE'
set -euo pipefail
repository="$1"
branch="$2"

rm -rf /root/openperouter
git clone --depth 1 --branch "${branch}" "${repository}" /root/openperouter
EOFSOURCE

echo "### Set up extra networks, create OpenPERouter CR, and verify deployment"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s << 'EOFDEPLOY'
set -euo pipefail
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh
export KUBECONFIG="/root/dev-scripts/ocp/${CLUSTER_NAME}/auth/kubeconfig"

CONFIG=/root/dev-scripts/config_root.sh \
  /root/openperouter/openshift/e2e/setup_extra_networks.sh

# Ensure namespace is privileged (router pods need host networking + nsenter)
oc label --overwrite ns openshift-openperouter-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

# Create OpenPERouter CR
cat <<'EOF' | oc apply -f -
apiVersion: network.openperouter.io/v1alpha1
kind: OpenPERouter
metadata:
  name: openperouter
  namespace: openshift-openperouter-system
spec:
  logLevel: debug
EOF

# Wait for controller and router daemonsets to be created and rolled out
for ds in controller router; do
  echo "Waiting for daemonset $ds to be created..."
  deadline=$((SECONDS + 300))
  until oc get daemonset "$ds" -n openshift-openperouter-system &>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "ERROR: Timed out waiting for daemonset $ds"
      exit 1
    fi
    sleep 5
  done
  oc rollout status daemonset/"$ds" -n openshift-openperouter-system --timeout=300s
done

echo "=== Deploy verification ==="
oc get pods -n openshift-openperouter-system -o wide
oc get daemonset -n openshift-openperouter-system

# Verify all pods are Running and Ready
NOT_READY=$(oc get pods -n openshift-openperouter-system --no-headers | grep -v "Completed" | grep -v "1/1\|2/2\|3/3\|4/4\|5/5" || true)
if [ -n "$NOT_READY" ]; then
  echo "ERROR: Some pods are not fully ready:"
  echo "$NOT_READY"
  exit 1
fi

echo "All openperouter pods are running and ready"

bash /root/openperouter/openshift/e2e/setup-clab.sh

cd /root/openperouter
CONTAINER_RUNTIME=podman make e2etests TEST_ARGS="--nodelink-config=$(pwd)/openshift/e2e/nodelink.json --frrk8s-namespace=openshift-frr-k8s \
--openperouter-namespace=openshift-openperouter-system" KUBECONFIG_PATH=$KUBECONFIG \
GINKGO_ARGS="--label-filter='systemdmode' --skip='editing the underlay parameters|auto-recover when the named netns is deleted|Webhook|Unnumbered' --focus='Baseline'"


EOFDEPLOY


