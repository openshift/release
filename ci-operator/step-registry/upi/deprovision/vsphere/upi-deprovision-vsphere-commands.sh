#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# TODO:
# Worse case scenario tear down
# Use govc to remove virtual machines if terraform fails

export HOME=/tmp
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere-aws/.awscred
export AWS_DEFAULT_REGION=us-east-1

installer_dir=/tmp/installer
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare cloud_where_run
declare target_hw_version
source "${SHARED_DIR}/vsphere_context.sh"

echo Deprovisioning $cluster_name

echo "$(date -u --rfc-3339=seconds) - Collecting vCenter performance data and alerts"

echo "{\"hw_version\":  \"vmx-${target_hw_version}\", \"cloud\": \"${cloud_where_run}\"}" > "${ARTIFACT_DIR}/runtime-config.json"

set +e
source "${SHARED_DIR}/govc.sh"
vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"
vcenter_state=${ARTIFACT_DIR}/vcenter_state
mkdir ${vcenter_state}

govc object.collect "/${GOVC_DATACENTER}/host" triggeredAlarmState &> ${vcenter_state}/host_alarms.log
govc metric.ls $vm_path/* | xargs govc metric.sample -json -n 60 $vm_path/* &> ${vcenter_state}/vm_metrics.json

clustervms=$(govc ls "${vm_path}")
for vm in $clustervms; do
echo Collecting alarms from $vm
echo " >>>> Alarms for: $vm" >> ${vcenter_state}/vm_alarms.log
govc object.collect $vm triggeredAlarmState &>> ${vcenter_state}/vm_alarms.log
done
set -e

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p "${installer_dir}/auth"
mkdir -p "${installer_dir}/secrets"
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/install-config.yaml" \
    "${SHARED_DIR}/metadata.json" \
    "${SHARED_DIR}/terraform.tfvars" \
    "${SHARED_DIR}/secrets.auto.tfvars" \
    "${SHARED_DIR}/variables.ps1" \
    "${SHARED_DIR}/bootstrap.ign" \
    "${SHARED_DIR}/worker.ign" \
    "${SHARED_DIR}/master.ign"

cp -t "${installer_dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"

if command -v pwsh &> /dev/null
then
  cp -t "${installer_dir}/secrets" \
      "${SHARED_DIR}/vcenter-creds.xml"
fi

# Copy sample UPI files
cp -rt "${installer_dir}" \
    /var/lib/openshift-install/upi/"${CLUSTER_TYPE}"/*

if ! command -v pwsh &> /dev/null
then
  tar -xf "${SHARED_DIR}/terraform_state.tar.xz"

  rm -rf .terraform || true
  terraform init -input=false -no-color

  # In some instances either the IPAM records or AWS DNS records
  # are removed before teardown is executed causing terraform destroy
  # to fail - this is causing resource leaks. Do not refresh the state.
  terraform destroy -refresh=false -auto-approve -no-color &
  wait "$!"
else
  pwsh -file upi-destroy.ps1 &
  wait "$!"
fi

