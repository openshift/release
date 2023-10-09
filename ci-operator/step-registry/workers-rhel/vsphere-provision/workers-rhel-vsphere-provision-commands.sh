#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

KUBECONFIG=${SHARED_DIR}/kubeconfig
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret

#Get vsphere platform info
vcenter_datacenter=$(oc get cm cloud-provider-config -n openshift-config -o json | jq -r .data.config | grep -oP 'datacenter = \K.*' | tr -d '\"')
vcenter_folder=$(oc get cm cloud-provider-config -n openshift-config -o json | jq -r .data.config | grep -oP 'folder = \K.*' | tr -d '\"')

echo "$(date -u --rfc-3339=seconds) - Config govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
export GOVC_FOLDER=${vcenter_folder}

set -x
infra_id=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)

#check tag exist
tag_number=1
if [[ $(govc tags.ls | grep ${infra_id} | wc -l) -eq 0 ]]; then
  tag_number=0
fi

#Start to provision rhel instances from template
for count in $(seq 1 ${RHEL_WORKER_COUNT}); do
  echo "$(date -u --rfc-3339=seconds) - Provision ${infra_id}-rhel-${count} ..."
  govc vm.clone -vm /${vcenter_datacenter}/vm/${RHEL_IMAGE} -on=false -net=${vsphere_portgroup} ${infra_id}-rhel-${count}
  govc vm.customize -vm ${vcenter_folder}/${infra_id}-rhel-${count} -name=${infra_id}-rhel-${count} -ip=dhcp
  govc vm.change -vm ${vcenter_folder}/${infra_id}-rhel-${count} -c ${RHEL_VM_CPUS_NUM} -m ${RHEL_VM_MEMORY_SIZE} -e disk.enableUUID=TRUE
  disk_name=$(govc device.info -json -vm ${vcenter_folder}/${infra_id}-rhel-${count} | jq -r '.Devices[]|select(.Type == "VirtualDisk")|.Name')
  govc vm.disk.change -vm ${vcenter_folder}/${infra_id}-rhel-${count} -disk.name ${disk_name} -size ${RHEL_VM_DISK_SIZE}G
  govc vm.power -on ${vcenter_folder}/${infra_id}-rhel-${count}
  [[ ${tag_number} -eq 1 ]] && govc tags.attach ${infra_id} ${vcenter_folder}/${infra_id}-rhel-${count}

  loop=10
  while [ ${loop} -gt 0 ]; do
    rhel_node_ip=$(govc vm.info -json ${vcenter_folder}/${infra_id}-rhel-${count} | jq -r .VirtualMachines[].Summary.Guest.IpAddress)
    if [ "x${rhel_node_ip}" == "x" ]; then
      loop=$((loop - 1))
      sleep 30
    else
      break
    fi
  done

  if [ "x${rhel_node_ip}" == "x" ]; then
    echo "Unabel to get ip of rhel instance ${infra_id}-rhel-${count}!"
    exit 1
  fi

  echo "${infra_id}-rhel-${count} ${rhel_node_ip}" >>"${SHARED_DIR}"/rhel_nodes_info
done
cp "${SHARED_DIR}"/rhel_nodes_info "${ARTIFACT_DIR}"/rhel_nodes_info

lb_group=""
lb_vars=""
if test -n "$(govc ls ${vcenter_folder} | grep "lb-0")"; then
  lb_ip="$(govc vm.info -json ${vcenter_folder}/lb-0 | jq -r .VirtualMachines[].Summary.Guest.IpAddress)"
  lb_group="[lb]\n${lb_ip}"
  lb_vars="[lb:vars]\nansible_user=core\nansible_become=True"
fi

#Generate ansible-hosts file
cat >"${SHARED_DIR}/ansible-hosts" <<EOF
[all:vars]
openshift_kubeconfig_path=${KUBECONFIG}
openshift_pull_secret_path=${PULL_SECRET_PATH}
ansible_ssh_common_args="-o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"

[new_workers:vars]
ansible_user=${SSH_USER}
ansible_become=True

$(echo -e ${lb_vars})

[new_workers]
# hostnames must be listed by what $(hostname -f) returns on the host
# this is the name the cluster will use
$(awk '{print $2}' "${SHARED_DIR}"/rhel_nodes_info)

$(echo -e ${lb_group})

[workers:children]
new_workers
EOF

cp "${SHARED_DIR}/ansible-hosts" "${ARTIFACT_DIR}"
