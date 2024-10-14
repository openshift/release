#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ${FOLDER} == "" ]]; then
    echo "FOLDER is not defined, skip check it"
    exit 0
fi
echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck disable=SC1091
source "${SHARED_DIR}/vsphere_context.sh"
echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
check_result=0

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
FOLDER_PATH=$(yq-go r "${INSTALL_CONFIG}" "platform.vsphere.failureDomains[0].topology.folder")

nodes_list=$(oc get nodes -ojson | jq -r '.items[].metadata.name')
folder_vm_list=$(govc ls -t VirtualMachine "$FOLDER_PATH" | awk -F "/" '{print $NF}')
echo "$FOLDER_PATH list: $folder_vm_list"
for node in $nodes_list; do
    folder_check_result=1
    for folder_vm in $folder_vm_list; do
        if [[ "$folder_vm" == "$node" ]]; then
            echo "Pass: passed to check machine: $node folder $FOLDER_PATH"
            folder_check_result=0
            break
        fi
    done
    if [[ $folder_check_result == 1 ]]; then
        echo "Fail: fail to check machine: $node folder $FOLDER_PATH"
        check_result=$((check_result + 1))
    fi
done

template_check_result=1
for folder_vm in $folder_vm_list; do
    if [[ $folder_vm =~ .*-rhcos-.* ]]; then
        echo "Pass: passed to check rhcos template are created under folder $FOLDER_PATH"
        template_check_result=0
        break
    fi
done
if [[ $template_check_result == 1 ]]; then
    echo "Fail: fail to check rhcos template are created under folder $FOLDER_PATH"
    check_result=$((check_result + 1))
fi

CM_FOLDER=$(oc get cm cloud-provider-config -n openshift-config -o jsonpath='{.data.config}' | awk '/^folder/{print $3}' | tr -d '"')
if [[ $FOLDER_PATH == "$CM_FOLDER" ]]; then
    echo "Pass: passed to check cloud-provider-config folder $CM_FOLDER, expected: $FOLDER_PATH"
else
    echo "Fail: fail to check cloud-provider-config folder $CM_FOLDER, expected: $FOLDER_PATH"
    check_result=$((check_result + 1))
fi

exit "${check_result}"
