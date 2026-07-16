#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'deploy_vm_bastion' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"

# TODO: Implement bastion VM deployment using Ansible playbook
# Playbook: playbooks/infra/deploy-vm-bastion-libvirt.yml
# Inventory: inventories/infra/deploy-vm-bastion-libvirt.yml
# Jenkins equivalent: jobs/Telco-KPIs/deploy-vm-libvirt.Jenkinsfile
#
# Implementation steps:
# 1. Derive MACHINE from HUB_CLUSTER: bastion.${HUB_CLUSTER}.telco-kpis.rdu3.redhat.com
# 2. Build Ansible inventory with hypervisor and bastion host variables
# 3. Execute playbook:
#    ansible-playbook ./playbooks/infra/deploy-vm-bastion-libvirt.yml \
#        -i ./inventories/infra/deploy-vm-bastion-libvirt.yml \
#        -e location=rdu
# 4. Playbook deploys VM on hypervisor via libvirt:
#    - Downloads RHEL qcow2 image, resizes disk
#    - Configures network via cloud-init (IP, gateway, DNS)
#    - Creates VM with redhatci.ocp.create_vms role
#    - Initial system setup: OS activation, user creation, SSH
#    - Bastion setup: packages, Go, registry, oc-mirror, certificates
#
# Jenkins vaults mapping:
#   ansible/ansible_group_bastions    -> /var/group_variables/common/bastions
#   ansible/ansible_group_all         -> /var/group_variables/common/all
#   ansible/ansible_group_hypervisors -> /var/group_variables/common/hypervisors
#   teams/telco-kpis/hypervisors/<hv> -> /var/host_variables/common/hypervisor
#   teams/telco-kpis/clusters/<cluster>/bastion.<cluster>... -> /var/host_variables/<cluster>/bastion

MACHINE="bastion.${HUB_CLUSTER}.telco-kpis.rdu3.redhat.com"

echo "TODO: Deploy bastion VM ${MACHINE} for hub cluster ${HUB_CLUSTER}"
echo "This step will execute Ansible playbook for bastion VM deployment"
echo "Required playbook: playbooks/infra/deploy-vm-bastion-libvirt.yml"
echo "Required inventory: inventories/infra/deploy-vm-bastion-libvirt.yml"
