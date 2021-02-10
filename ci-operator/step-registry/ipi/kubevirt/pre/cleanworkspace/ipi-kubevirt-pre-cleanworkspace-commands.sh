#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "Tenant cluster: ${LEASED_RESOURCE}"

HOME=/tmp
KUBEVIRT_NAMESPACE=ipi-ci
KUBECONFIG_KUBEVIRT_IPI=${HOME}/secret-kube/kubeconfig-infra-cluster
TENANT_NAME="t${LEASED_RESOURCE: -1}"

echo "Tenant Name: ${TENANT_NAME}"
VMS=$(oc --kubeconfig=${KUBECONFIG_KUBEVIRT_IPI} -n ${KUBEVIRT_NAMESPACE} get vms)

if [[ -z "${VMS}" ]] || [[ "${VMS}" != *"${TENANT_NAME}"* ]]; then
  echo "No VMs were found for Tenant Name: ${TENANT_NAME}"
  exit
fi

VM=$(oc --kubeconfig=${KUBECONFIG_KUBEVIRT_IPI} -n ${KUBEVIRT_NAMESPACE} get vms | grep "${TENANT_NAME}" | awk '{print $1}'|head -n 1)

echo "Found at least one VM ${VM}"
IFS='-'
read -a strarr <<<"$VM"
LABEL="tenantcluster-${TENANT_NAME}-${strarr[1]}-machine.openshift.io=owned"
IFS=''
echo "Found resources with the label: \"${LABEL}\" that need to be deleted"

echo "Deleteing virtual machines with that label"
oc delete vms -l "${LABEL}" -n ${KUBEVIRT_NAMESPACE} --kubeconfig=${KUBECONFIG_KUBEVIRT_IPI}

echo "Deleteing datavolumes with that label"
oc delete dv -l "${LABEL}" -n ${KUBEVIRT_NAMESPACE} --kubeconfig=${KUBECONFIG_KUBEVIRT_IPI}

echo "Deleteing secrets with that label"
oc delete secret -l "${LABEL}" -n ${KUBEVIRT_NAMESPACE} --kubeconfig=${KUBECONFIG_KUBEVIRT_IPI}
