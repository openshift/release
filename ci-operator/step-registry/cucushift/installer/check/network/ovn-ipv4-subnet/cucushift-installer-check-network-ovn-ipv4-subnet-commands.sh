#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ovn_ipv4_subnet_from_config=$(yq-go r "${SHARED_DIR}/install-config.yaml" "networking.ovnKubernetesConfig.ipv4.internalJoinSubnet")
ovn_ipv4_subnet_in_cluster=$(oc get networks.operator.openshift.io cluster -ojson | jq -r ".spec.defaultNetwork.ovnKubernetesConfig.ipv4.internalJoinSubnet")

echo "ovn_ipv4_subnet_from_config: ${ovn_ipv4_subnet_from_config}"
echo "ovn_ipv4_subnet_in_cluster: ${ovn_ipv4_subnet_in_cluster}"

if [[ "${ovn_ipv4_subnet_from_config}" == "${ovn_ipv4_subnet_in_cluster}" ]]; then
    echo "PASS: networking.ovnKubernetesConfig.ipv4.internalJoinSubnet setting correctly!"
else
    echo "FAIL: networking.ovnKubernetesConfig.ipv4.internalJoinSubnet setting incorrectly!"
    exit 1
fi
