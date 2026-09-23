#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
additional_ca=$(yq-go r "${INSTALL_CONFIG}" 'additionalTrustBundle')
additional_ca_policy=$(yq-go r "${INSTALL_CONFIG}" 'additionalTrustBundlePolicy')
proxy_setting=$(yq-go r "${INSTALL_CONFIG}" 'proxy')

if [[ -z "${additional_ca}" ]]; then
    echo "The additional CA is not set, ignore checking"
    exit 0
fi

echo "------check trustedCA configured in the proxy spec------"
trustedCA_name=$(oc get proxy cluster -ojson | jq -r ".spec.trustedCA.name")
echo "The configured trusted CA name in proxy object is: ${trustedCA_name}"

check_result=0

if [[ "${proxy_setting}" != "" ]]; then
    if [[ "${trustedCA_name}" != "user-ca-bundle" ]]; then
        echo "ERROR: the trusted CA configured in proxy object is not expected!"
        check_result=1
    else
        echo "INFO: the trusted CA configured as expected"
    fi
else
    if [[ "${additional_ca_policy}" == "Always" ]]; then
        if [[ "${trustedCA_name}" != "user-ca-bundle" ]]; then
            echo "ERROR: the trusted CA configured in proxy object is not expected!"
            check_result=1
        else
            echo "INFO: the trusted CA configured as expected"
        fi
    fi

    if [[ "${additional_ca_policy}" == "" || "${additional_ca_policy}" == "Proxyonly" ]]; then
        if [[ "${trustedCA_name}" != "" ]]; then
            echo "ERROR: the trusted CA configured in proxy object is not expected!"
            check_result=1
        else
            echo "INFO: the trusted CA configured as expected"
        fi
    fi
fi

exit ${check_result}
