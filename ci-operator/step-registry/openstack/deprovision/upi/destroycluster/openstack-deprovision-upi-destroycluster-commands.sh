#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OS_SUBNET_RANGE=$(<"${SHARED_DIR}/OS_SUBNET_RANGE")
NUMBER_OF_WORKERS=$(<"${SHARED_DIR}/NUMBER_OF_WORKERS")
NUMBER_OF_MASTERS=$(<"${SHARED_DIR}/NUMBER_OF_MASTERS")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
OPENSTACK_COMPUTE_FLAVOR="${OPENSTACK_COMPUTE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")}"
OPENSTACK_MASTER_FLAVOR=$(<"${SHARED_DIR}/OPENSTACK_MASTER_FLAVOR")
LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)
INGRESS_FIP_IP=$(<"${SHARED_DIR}"/INGRESS_FIP_IP)
BOOTSTRAP_FIP_IP=$(<"${SHARED_DIR}/BOOTSTRAP_FIP_IP")
RHCOS_IMAGE_ID=$(<"${SHARED_DIR}/RHCOS_IMAGE_ID")



ASSETS_DIR=/tmp/assets_dir
rm -rf ${ASSETS_DIR}
mkdir -p ${ASSETS_DIR}

# Copy the playbooks into the assets directory
cp "${OS_UPI_DIR}/common.yaml" "${ASSETS_DIR}"

# Playbook numbers were removed in in 4.5
if [ -f "${OS_UPI_DIR}/01_security-groups.yaml" ]; then
  cp "${OS_UPI_DIR}/01_security-groups.yaml"      "${ASSETS_DIR}/security-groups.yaml"
  cp "${OS_UPI_DIR}/02_network.yaml"              "${ASSETS_DIR}/network.yaml"
  cp "${OS_UPI_DIR}/03_bootstrap.yaml"            "${ASSETS_DIR}/bootstrap.yaml"
  cp "${OS_UPI_DIR}/04_control-plane.yaml"        "${ASSETS_DIR}/control-plane.yaml"
  cp "${OS_UPI_DIR}/05_compute-nodes.yaml"        "${ASSETS_DIR}/compute-nodes.yaml"

  cp "${OS_UPI_DIR}/down-01_security-groups.yaml" "${ASSETS_DIR}/down-security-groups.yaml"
  cp "${OS_UPI_DIR}/down-02_network.yaml"         "${ASSETS_DIR}/down-network.yaml"
  cp "${OS_UPI_DIR}/down-03_bootstrap.yaml"       "${ASSETS_DIR}/down-bootstrap.yaml"
  cp "${OS_UPI_DIR}/down-04_control-plane.yaml"   "${ASSETS_DIR}/down-control-plane.yaml"
  cp "${OS_UPI_DIR}/down-05_compute-nodes.yaml"   "${ASSETS_DIR}/down-compute-nodes.yaml"
  cp "${OS_UPI_DIR}/down-06_load-balancers.yaml"  "${ASSETS_DIR}/down-load-balancers.yaml"
else
  cp \
    "${OS_UPI_DIR}/security-groups.yaml"      \
    "${OS_UPI_DIR}/network.yaml"              \
    "${OS_UPI_DIR}/bootstrap.yaml"            \
    "${OS_UPI_DIR}/control-plane.yaml"        \
    "${OS_UPI_DIR}/compute-nodes.yaml"        \
                                              \
    "${OS_UPI_DIR}/down-security-groups.yaml" \
    "${OS_UPI_DIR}/down-network.yaml"         \
    "${OS_UPI_DIR}/down-bootstrap.yaml"       \
    "${OS_UPI_DIR}/down-control-plane.yaml"   \
    "${OS_UPI_DIR}/down-compute-nodes.yaml"   \
    "${OS_UPI_DIR}/down-load-balancers.yaml"  \
                                              \
    "${ASSETS_DIR}"
fi
# down-containers.yaml was introduced in 4.6
if [ -f "${OS_UPI_DIR}/down-containers.yaml" ]; then
  cp "${OS_UPI_DIR}/down-containers.yaml" "${ASSETS_DIR}"
else
  # If not present, create a valid empty playbook.
sed -n '/tasks/q;p' "${ASSETS_DIR}/network.yaml" > "${ASSETS_DIR}/down-containers.yaml"
fi
tar -xzf "${SHARED_DIR}"/assetsdir.tgz  -C ${ASSETS_DIR}


sed "
  0,/os_subnet_range:.*/         {s||os_subnet_range: \'${OS_SUBNET_RANGE}\'|}                ;
  0,/os_flavor_master:.*/        {s||os_flavor_master: \'${OPENSTACK_MASTER_FLAVOR}\'|}              ;
  0,/os_flavor_worker:.*/        {s||os_flavor_worker: \'${OPENSTACK_COMPUTE_FLAVOR}\'|}              ;
  0,/os_image_rhcos:.*/          {s||os_image_rhcos: \'${RHCOS_IMAGE_ID}\'|}         ;
  0,/os_external_network:.*/     {s||os_external_network: \'${OPENSTACK_EXTERNAL_NETWORK}\'|} ;
  0,/os_api_fip:.*/              {s||os_api_fip: \'${LB_FIP_IP}\'|}                           ;
  0,/os_ingress_fip:.*/          {s||os_ingress_fip: \'${INGRESS_FIP_IP}\'|}                  ;
  0,/os_bootstrap_fip:.*/        {s||os_bootstrap_fip: \'${BOOTSTRAP_FIP_IP}\'|}              ;
  0,/os_cp_nodes_number:.*/      {s||os_cp_nodes_number: ${NUMBER_OF_MASTERS}|}               ;
  0,/os_compute_nodes_number:.*/ {s||os_compute_nodes_number: ${NUMBER_OF_WORKERS}|}          ;
  " "${OS_UPI_DIR}/inventory.yaml" > "${ASSETS_DIR}/inventory.yaml"

#lets verify the playbooks integrity before a real run
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-load-balancers.yaml"
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-compute-nodes.yaml"
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-control-plane.yaml"
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-bootstrap.yaml"
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-network.yaml"
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-security-groups.yaml"
ansible-playbook --list-tasks -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-containers.yaml"

ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-load-balancers.yaml"
ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-compute-nodes.yaml"
ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-control-plane.yaml"
ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-bootstrap.yaml"
ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-network.yaml"
ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-security-groups.yaml"
ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/down-containers.yaml"