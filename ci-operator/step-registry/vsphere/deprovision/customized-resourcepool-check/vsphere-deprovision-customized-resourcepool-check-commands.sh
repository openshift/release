#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
rsp_config=$(yq-go r ${INSTALL_CONFIG} 'platform.vsphere.failureDomains[*].topology.resourcePool')

if [[ -z ${rsp_config} ]];then
    echo "resource pool not defined in install-config. skip this step"
    exit 0
fi

if [[ -n "$(govc ls ${rsp_config})" ]];then
    echo "customized resource pool ${rsp_config} was not deleted after cluster destroyed. that is expected"
else
    echo "customized resource pool ${rsp_config} not exists after cluster destroyed, please check"   
    exit 1
fi

if govc pool.info -json ${rsp_config} | jq -r '.ResourcePools[].Vm[] | join(":")' | xargs govc ls -L | awk -F'/' '{print $NF}' | grep -q ${INFRA_ID};then
    echo "vm found in resource pool after cluster destroy, please check"
    exit 1
else
    echo "all cluster machines were removed from resource pool ${rsp_config}."
fi


