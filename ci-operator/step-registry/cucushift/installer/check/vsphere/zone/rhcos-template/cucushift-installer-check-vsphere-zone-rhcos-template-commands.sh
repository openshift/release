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
    local check_result=0 fd_folder fd_datacenter fd_region fd_zone fd_template
    # shellcheck disable=SC2207
    for name in "${zones_name_from_config[@]}"; do
	fd_template=$(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains.(name==${name}).topology.template")
        if [[ -n "${fd_template}" ]]; then
            echo "temmplate ${fd_template} specify in failureDomain ${name}, installer will use pre-existing template instead of importing new template, skip the check of auto imported rhcos images"
            continue
        fi
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
    if [[ -f "${SHARED_DIR}/.openshift_install.log" ]]; then
        echo "installation log found"
        if [[ $(yq-go r ${INSTALL_CONFIG} "platform.vsphere.failureDomains[*].topology.template" | wc -l) == "${#zones_name_from_config[@]}" ]];then
	    if grep -q "Obtaining RHCOS image file" "${SHARED_DIR}"/.openshift_install.log; then
              echo "Fail: template defined in install-config, should not import ova"
	      check_result=1
	    else
	      echo "Pass: template defined in install-config, skip importing ova"
	    fi
        else
	    if grep -q "Obtaining RHCOS image file" "${SHARED_DIR}"/.openshift_install.log; then
              echo "Pass: not all templates defined in install-config, the log will print info about importing ova"
	    else
              echo "Fail: the log about importing ova not displayed, please check template field in install-config"
              check_result=1
            fi
	fi
        rm -f "${SHARED_DIR}"/.openshift_install.log	
    else
        echo "installation log not found"
        check_result=1
    fi
}

check_rhcos || check_result=1


exit ${check_result}
