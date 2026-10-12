#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Version comparison functions using sort -V
function version_ge() {
  # Returns 0 (true) if $1 >= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

if [[ "$NETWORK_MTU" == "" ]]; then
  echo "error: NETWORK_MTU is empty, exit now"
  exit 1
fi

network_type=$(cat "${SHARED_DIR}/install-config.yaml" | grep networkType | awk '{print $2}' || true)

if [[ "${network_type}" == "" ]]; then
  # default
  cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
  oc registry login --to /tmp/pull-secret
  ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
  rm /tmp/pull-secret
  if version_ge "${ocp_version}" "4.12"; then
    network_type="OVNKubernetes"
  else
    network_type="OpenShiftSDN"
  fi
fi

echo "network_type: $network_type"

manifest_file="${SHARED_DIR}/manifest_cluster-network-03-mtu-config.yaml"

if [[ "${network_type}" == "OpenShiftSDN" ]]; then
  cat <<EOF >"${manifest_file}"
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    openshiftSDNConfig:
      mtu: ${NETWORK_MTU}
EOF
fi

if [[ "${network_type}" == "OVNKubernetes" ]]; then
  cat <<EOF >"${manifest_file}"
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      mtu: ${NETWORK_MTU}
EOF
fi

echo "Network MTU config:"
cat $manifest_file
