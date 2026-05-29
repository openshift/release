#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && { echo "Proxy conf file is not found. Failing."; exit 1; }

source "${SHARED_DIR}/proxy-conf.sh"
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET=$(jq -c -n '{"auths":{"test":{"auth":"dXNlcjpwYXNzCg=="}}}')
RENDEZVOUS_IP=$(<"${SHARED_DIR}/node-zero-ip.txt")
PROXY_URL=$(<"${CLUSTER_PROFILE_DIR}/proxy")

export CLUSTER_NAME
export BASE_DOMAIN
export PULL_SECRET
export RENDEZVOUS_IP
export PROXY_URL
export USER_MANAGED_NETWORKING=true

if ! python3.11 assisted-ui/run_agent_tui.py; then
 echo "Assisted UI workflow failed."
 cp /tmp/assisted_ui.log "$ARTIFACT_DIR"
 cp -r /tmp/screenshots/* "$ARTIFACT_DIR"
 exit 1
fi

cp "/tmp/kubeconfig" "${SHARED_DIR}/kubeconfig"
cp "/tmp/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"

export KUBECONFIG=/tmp/kubeconfig

# During bootstrap, the kube-apiserver serves a temporary certificate that lacks
# the external API hostname SAN. TLS verification must be skipped until the
# kube-apiserver-operator rotates the serving certificate.
oc config set-cluster "$(oc config view -o jsonpath='{.clusters[0].name}')" \
  --insecure-skip-tls-verify=true --kubeconfig=/tmp/kubeconfig

API_URL=$(oc config view -o jsonpath='{.clusters[0].cluster.server}' --kubeconfig=/tmp/kubeconfig)

echo "$(date -u --rfc-3339=seconds) - Waiting for API server at ${API_URL} to become reachable..."
API_READY=false
for i in $(seq 1 360); do
  if oc get --raw /readyz &>/dev/null; then
    echo "$(date -u --rfc-3339=seconds) - API server is reachable."
    API_READY=true
    break
  fi
  if (( i % 20 == 0 )); then
    echo "$(date -u --rfc-3339=seconds) - Still waiting for API server... (attempt ${i}/360)"
  fi
  sleep 30
done

if [ "${API_READY}" = false ]; then
  echo "ERROR: API server did not become reachable within 3 hours."
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Checking cluster installation progress by verifying all cluster operators are available and stable."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=90m

# Re-enable TLS verification for next steps
oc config set-cluster "$(oc config view -o jsonpath='{.clusters[0].name}')" \
  --insecure-skip-tls-verify=false --kubeconfig=/tmp/kubeconfig
cp "/tmp/kubeconfig" "${SHARED_DIR}/kubeconfig"
