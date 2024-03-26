#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set +x
export KUBECONFIG=${SHARED_DIR}/kubeconfig

installer_dir=/tmp/installer
echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p "${installer_dir}"
pushd ${installer_dir}
cp -t "${installer_dir}" \
    "${SHARED_DIR}/install-config.yaml"

template_config=$(cat install-config.yaml | grep template |awk -F ' ' '{print $2}')
template_config=${template_config##*/}
template_cluster=$(oc get machineset -n openshift-machine-api -ojson | jq -r '.items[].spec.template.spec.providerSpec.value.template')
template_cluster=${template_cluster##*/}
if [[ ${template_config} != "${template_cluster}" ]]; then
    echo "ERROR: template specify in install-config is ${template_config},  not same as cluster's template ${template_cluster}. please check"
    exit 1
else 
    echo "INFO template specify in install-config is ${template_config}, same as cluster's template ${template_cluster}. check successful "
    exit 0
fi
