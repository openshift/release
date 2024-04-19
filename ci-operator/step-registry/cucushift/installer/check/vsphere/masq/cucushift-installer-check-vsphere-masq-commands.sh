#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

check_result=0

gatewayConfig_v4=$(oc get get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipv4.internalMasqueradeSubnet}'
gatewayConfig_v6=$(oc get get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipv6.internalMasqueradeSubnet}'

if [[ $gatewayConfig_v4 == "100.254.169.0/29" ]] || [[ $gatewayConfig_v6 == "abcd:ef01:2345:6789:abcd:ef01:2345:6789/125" ]]; then
    echo "Pass: masq subnet check passed"
    check_result=1
fi
   
exit "${check_result}"
