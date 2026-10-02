#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
export HTTP_PROXY=${proxy}
export HTTPS_PROXY=${proxy}

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET=$(jq -c -n '{"auths":{"test":{"auth":"dXNlcjpwYXNzCg=="}}}')
RENDEZVOUS_IP=$(<"${SHARED_DIR}/node-zero-ip.txt")
PROXY_URL=$(<"${CLUSTER_PROFILE_DIR}/proxy")

export CLUSTER_NAME BASE_DOMAIN PULL_SECRET RENDEZVOUS_IP PROXY_URL \
       WORKER_MACS="" TOPOLOGY_TYPE="${TOPOLOGY_TYPE:-COMPACT}" ADDITIONAL_OPERATORS="${ADDITIONAL_OPERATORS:-}"

if [[ "${TOPOLOGY_TYPE}" == "HA" ]]; then
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
     name=$(echo "$bmhost" | jq -r '.name')
     if [[ "$name" == *"worker"* ]]; then
       mac_address=$(echo "$bmhost" | jq -r '.mac')
       WORKER_MACS="$WORKER_MACS,$mac_address"
     fi
  done
fi

if [[ "${LOAD_BALANCER_TYPE:-cluster-managed}" == "cluster-managed" && "${TOPOLOGY_TYPE}" != "SNO" ]]; then
  API_IP=$(yq ".api_vip" "${SHARED_DIR}/vips.yaml")
  INGRESS_IP=$(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")
  export API_IP INGRESS_IP
else
  export USER_MANAGED_NETWORKING=true
fi

if ! python3.11 assisted-ui/run_agent_tui.py; then
 echo "Assisted UI workflow failed."
 cp -r /tmp/screenshots/* "$ARTIFACT_DIR"
 cp -r /tmp/videos/* "$ARTIFACT_DIR"
 exit 1
fi

cp "/tmp/kubeconfig" "${SHARED_DIR}/kubeconfig"
cp "/tmp/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"

export KUBECONFIG=/tmp/kubeconfig
wait_time=3h
if [ "${VENDOR:-dell}" = "hpe" ]; then
  wait_time=1h
fi
echo "Forcing a $wait_time delay to allow other machines to join the bootstrap node."
sleep "$wait_time"

echo "Checking cluster installation progress by verifying all cluster operators are available and stable."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=105m

# Replicate https://github.com/openshift/release/blob/main/ci-operator/step-registry/baremetalds/devscripts/setup/baremetalds-devscripts-setup-commands.sh#L32
# Add proxy config in this step and leave conformance test step untouched
echo "Adding proxy-url in kubeconfig for e2e conformance tests"
sed -i "/- cluster/ a\    proxy-url: ${proxy}" "${SHARED_DIR}"/kubeconfig