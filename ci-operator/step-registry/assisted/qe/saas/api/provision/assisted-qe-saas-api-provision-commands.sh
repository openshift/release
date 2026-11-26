#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
qe_remote provision "$QE_PROVISION_TIMEOUT" <<'REMOTE'
source "$WORKSPACE/api.env"
test -f "$WORKSPACE/prepared"
source "$VENV/bin/activate"
export ANSIBLE_FILTER_PLUGINS="$HOME/.ansible/plugins/filter:/usr/share/ansible/plugins/filter:$BASE_REPO_DIR/linchpin-workspace/hooks/ansible/ocp-edge-setup/filter_plugins"

cd "$TFDEST"
if [ -e .terraform.lock.hcl ]; then rm -rf .terraform.lock.hcl; fi

echo "Initializing Terraform!"

terraform init

echo "Pre-cleanup: destroying stale AI VMs"
for vm in $(sudo virsh list --all --name | grep -E "^(master|worker)-" || true); do
    echo "Destroying VM: ${vm}"
    sudo virsh destroy "$vm" || true
    sudo virsh undefine "$vm" --nvram --remove-all-storage || true
done

cd "$TFDEST"
if [ -e /var/tmp/terraform-assisted.tfstate ]; then
    terraform refresh \
    -state=/var/tmp/terraform-assisted.tfstate

    terraform destroy \
    -input=false \
    -auto-approve \
    -state=/var/tmp/terraform-assisted.tfstate

    rm -f /var/tmp/terraform-assisted.tfstate
    rm -f /var/tmp/terraform-assisted.tfstate.backup
fi

source "$VENV/bin/activate"
cd "$BASE_REPO_DIR"
export ANSIBLE_FORCE_COLOR=true

ansible-playbook -e "ansible_python_interpreter=$SYSTEM_PYTHON" --connection=local -i localhost, \
linchpin-workspace/hooks/ansible/ocp-edge-setup/assisted_cleanup_hypervisor.yml

ansible-playbook -e "ansible_python_interpreter=$SYSTEM_PYTHON" -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml -i localhost, \
--connection=local linchpin-workspace/hooks/ansible/ocp-edge-setup/assisted_cleanup_etc_hosts.yml

ansible-playbook -e "ansible_python_interpreter=$SYSTEM_PYTHON" -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml -i localhost, \
--connection=local linchpin-workspace/hooks/ansible/ocp-edge-setup/assisted_cleanup_iptables.yml

ansible-playbook -e "ansible_python_interpreter=$SYSTEM_PYTHON" -e container_name=squid,load_balancer -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml -i localhost, \
--connection=local linchpin-workspace/hooks/ansible/ocp-edge-setup/cleanup_containers.yml

ansible-playbook -e "ansible_python_interpreter=$SYSTEM_PYTHON" -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml -i localhost, \
--connection=local linchpin-workspace/hooks/ansible/ocp-edge-setup/assert-disk-space.yaml

cd "$TFDEST"
terraform apply \
    -var="domain_pub_key=${SSH_PUB_KEY}" \
    -var="baremetal_net_ipv6=${BAREMETAL_NET_IPV6}" \
    -var="baremetal_net_ipv4=${BAREMETAL_NET_IPV4}" \
    -var="ipv4_range_start=${IPV4_RANGE_START}" \
    -var="ipv4_range_end=${IPV4_RANGE_END}" \
    -var="base_domain=${BASE_DOMAIN}" \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="add_provisionhost=${ADD_PROVISIONHOST}" \
    -var="provisionhost_volume_size=${PROVISIONHOST_DISK_SIZE}" \
    -var="master_count=${PROVISION_MASTER_COUNT}" \
    -var="master_memory=${MASTER_MEMORY}" \
    -var="master_vcpus=${MASTER_VCPUS}" \
    -var="master_extra_disk_count=${MASTER_EXTRA_DISKS_NUMBER}" \
    -var="master_extra_disk_size=${MASTER_EXTRA_DISKS_SIZE}" \
    -var="worker_count=${PROVISION_WORKER_COUNT}" \
    -var="worker_memory=${WORKER_MEMORY}" \
    -var="worker_vcpus=${WORKER_VCPUS}" \
    -var="worker_extra_disk_count=${WORKER_EXTRA_DISKS_NUMBER}" \
    -var="worker_extra_disk_size=${WORKER_EXTRA_DISKS_SIZE}" \
    -var="worker_name=${ASSISTED_WORKER_NAME}" \
    -var="cluster_count=${CLUSTER_COUNT}" \
    -var="static_ip_bond=${BOND}" \
    -var="virtio_gpu=${VIRT_GPU}" \
    -var="os_major_version=${OS_MAJOR_VERSION}" \
    -input=false \
    -auto-approve
cp tf-ai-ansible-inventory "$BASE_REPO_DIR"
cp tf-ai-ansible-inventory "$BASE_REPO_DIR/linchpin-workspace/inventories/ocp-edge.inventory"

source "$VENV/bin/activate"
cd "$BASE_REPO_DIR"
export ANSIBLE_FORCE_COLOR=true
export ANSIBLE_FILTER_PLUGINS="$HOME/.ansible/plugins/filter:/usr/share/ansible/plugins/filter:$BASE_REPO_DIR/linchpin-workspace/hooks/ansible/ocp-edge-setup/filter_plugins"
ansible-playbook \
    -i tf-ai-ansible-inventory \
    linchpin-workspace/hooks/ansible/ocp-edge-setup/prepare_hosts_for_assisted_tf.yaml \
    --vault-password-file "$OCM_VAULT_CRED" \
    -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml \
    -e "ansible_python_interpreter=$SYSTEM_PYTHON" \
    -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/vault_files/ocp_secrets_ai_saas.yaml

source "$VENV/bin/activate"
cd "$BASE_REPO_DIR"
export ANSIBLE_FORCE_COLOR=true
export ANSIBLE_FILTER_PLUGINS="$HOME/.ansible/plugins/filter:/usr/share/ansible/plugins/filter:$BASE_REPO_DIR/linchpin-workspace/hooks/ansible/ocp-edge-setup/filter_plugins"
ansible-playbook \
    -i tf-ai-ansible-inventory \
    linchpin-workspace/hooks/ansible/ocp-edge-setup/assisted-installer-dns-update-tf.yaml \
    -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml \
    -e "ansible_python_interpreter=$SYSTEM_PYTHON"

if [ "$VLAN" == 'true' ]; then
    echo "Setup VLAN for AI"
    cd "$BASE_REPO_DIR"
    export ANSIBLE_FORCE_COLOR=true
    source "$VENV/bin/activate"
    ansible-playbook \
        -i tf-ai-ansible-inventory \
        linchpin-workspace/hooks/ansible/ocp-edge-setup/assisted-installer-vlan.yaml \
        -e @linchpin-workspace/hooks/ansible/ocp-edge-setup/extravars.yaml \
        -vv
fi
REMOTE
