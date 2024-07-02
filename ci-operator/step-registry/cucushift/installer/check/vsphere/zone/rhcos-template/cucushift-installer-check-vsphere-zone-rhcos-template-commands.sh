#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
# These two environment variables are coming from vsphere_context.sh and
# the file they are assigned to is not available in this step.
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"

check_result=0
readarray -t zones_name_from_config < <(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains[*].name")
infra_id=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)

function check_rhcos() {
    local check_result=0 fd_folder fd_datacenter fd_region fd_zone
    # shellcheck disable=SC2207
    for name in "${zones_name_from_config[@]}"; do
        fd_folder=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(name==${name}).topology.folder")
	fd_datacenter=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(name==${name}).topology.datacenter")
        [[ -z "${fd_datacenter}" ]] && fd_datacenter=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.datacenter")
	fd_region=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(name==${name}).region")
	fd_zone=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(name==${name}).zone")
	[[ -z "${fd_folder}" ]] && fd_folder="/${fd_datacenter}/vm/${infra_id}"
        if [[ -n "$(govc ls ${fd_folder})" ]]; then
	    echo "INFO: folder ${fd_folder} created successful"
	    if [[ -n "$(govc ls ${fd_folder}/${infra_id}-rhcos-${fd_region}-${fd_zone})" ]]; then
	        echo "INFO: rhcos image ${infra_id}-rhcos-${fd_region}-${fd_zone} uploaded to specified failureDomain"
	    else
		check_result=1
	        echo "INFO: rhcos image ${infra_id}-rhcos-${fd_region}-${fd_zone} not found in specified failureDomain"
            fi
	else
            check_result=1
	    echo "ERROR: folder ${fd_folder}  not found"
	fi

    done

    return ${check_result}
}

check_rhcos || check_result=1


exit ${check_result}
