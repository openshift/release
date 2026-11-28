#!/bin/bash
set -euo pipefail
source "${SHARED_DIR}/qe-ssh.sh"
[[ "$OCP_EDGE_REPO" == https://* && "$OCP_EDGE_REF" =~ ^[0-9a-f]{40}$ ]]
qe_export OCP_EDGE_REPO OCP_EDGE_REF ASSISTED_API_ENDPOINT ASSISTED_TEST_INFRA_MARKER ASSISTED_TEST_INFRA_BRANCH KNI_ASSISTED_INSTALLER_AUTO_BRANCH ASSISTED_FUNCTIONAL_API_TESTS_PARALLEL OCM_USER SECOND_OCM_USER_FOR_AUTH_TESTS PROVISION_MASTER_COUNT PROVISION_WORKER_COUNT DEPLOY_MASTER_COUNT DEPLOY_WORKER_COUNT MASTER_MEMORY WORKER_MEMORY MASTER_VCPUS WORKER_VCPUS MASTER_DISK_SIZE WORKER_DISK_SIZE NETWORK_TYPE BASE_DOMAIN PROFILE_NAME
qe_remote prepare "$QE_PREPARE_TIMEOUT" <<'REMOTE'
for credential in ocm-vault-password route53-vault-password; do
    test -s "$QE_SECRETS_DIR/$credential"
done
cat > "$WORKSPACE/api.env" <<'ENVIRONMENT'
export ADD_ADDITIONAL_TRUST_BUNDLE=false
export ADD_PROVISIONHOST=false
export ADVANCED_NETWORKING=false
export ASSISTED_CLEANUP_NUTANIX=true
export ASSISTED_CLUSTER_NETWORK_CIDR=10.128.0.0/14
export ASSISTED_CLUSTER_NETWORK_HOST_PREFIX=23
export ASSISTED_CUSTOM_MANIFESTS=false
export ASSISTED_DEPLOYMENT_VALIDATIONS_REPORTING=false
export ASSISTED_DEPLOY_CNV_OPERATOR=false
export ASSISTED_DEPLOY_LVM_OPERATOR=false
export ASSISTED_DEPLOY_MCE_OPERATOR=false
export ASSISTED_DEPLOY_NAMESPACE=assisted-installer
export ASSISTED_DEPLOY_NMSTATE_OPERATOR=false
export ASSISTED_DEPLOY_NUTANIX_CSI_OPERATOR=false
export ASSISTED_DEPLOY_OCS_OPERATOR=false
export ASSISTED_DEPLOY_OPENSHIFT_AI_OPERATOR_TYPE=None
export ASSISTED_DEPLOY_TAG=stable
export ASSISTED_DEPLOY_TEST_CASE_ID=''
export ASSISTED_DEPLOY_VIRTUALIZATION_BUNDLE=false
export ASSISTED_DNS_PTR_RECORD=false
export ASSISTED_IMAGE_SERVICE_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-image-service:latest
export ASSISTED_INSTALLER_AGENT_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-installer-agent:latest
export ASSISTED_INSTALLER_CONTROLLER_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-installer-controller:latest
export ASSISTED_INSTALLER_UI=''
export ASSISTED_LOCAL_REGISTRY_INSTALL=false
export ASSISTED_MINIMAL_ISO=false
export ASSISTED_OCP_NETWORK_CONFIGURATION=Default
export ASSISTED_POLARION_TESTRUN_ID=''
export ASSISTED_POST_DEPLOYMENT_API_DAY2_TESTS=false
export ASSISTED_POST_DEPLOYMENT_UI_DAY2_TESTS=false
export ASSISTED_RUN_FUNCTIONAL_API_TESTS=true
export ASSISTED_RUN_RESILIENCE_UPGRADE_API_TESTS=false
export ASSISTED_SERVICE_BRANCH=master
export ASSISTED_SERVICE_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-service:latest
export ASSISTED_SERVICE_NETWORK_CIDR=172.30.0.0/16
export ASSISTED_STATIC_IP=false
export ASSISTED_STATIC_IP_FLOW='Form view'
export ASSISTED_STATIC_IP_VERSION=ipv4
export ASSISTED_STATIC_IP_VLAN_ID=404
export ASSISTED_TEST_BROWSER=chrome
export ASSISTED_TEST_INFRA_REPO=https://github.com/openshift/assisted-test-infra.git
export ASSISTED_TEST_INFRA_TEST_NAME=''
export ASSISTED_UI_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-installer-ui:latest
export ASSISTED_UI_REVISION=''
export ASSISTED_UI_SPEC_FILE=''
export ASSISTED_UI_VALIDATIONS=false
export ASSISTED_USE_OCP_UI_VMWARE_CONFIGURATION=false
export ASSISTED_WORKER_NAME=worker
export ASSSITED_UI_IGNORE_TEST_FILES=''
export BAREMETAL_NET_IPV4=true
export BAREMETAL_NET_IPV6=false
export BOND=false
export CARBON_TEST_REPORTING=false
export CLUSTER_COUNT=1
export CPU_ARCHITECTURE=x86_64
export CYPRESS_GREPTAG=''
export DEPLOY_ASSISTED_ON=None
export DISCONNECTED_INSTALL=false
export DISK_ENABLE_UUID_VMWARE=TRUE
export DUAL_STACK_PATCH=false
export ENABLE_IMAGE_REGISTRY_STORAGE=false
export FACET_DOWNSTREAM_BRANCH=master
export FACET_DOWNSTREAM_REPO=https://gitlab.cee.redhat.com/ocp-edge-qe/kni-assisted-installer-auto.git
export HTTP_AUTHENTICATED_PROXY_USE=false
export IPV4_RANGE_END=150
export IPV4_RANGE_START=50
export KNI_ASSISTED_INSTALLER_AUTO_REPO=https://gitlab.cee.redhat.com/ocp-edge-qe/kni-assisted-installer-auto.git
export MANAGEMENT_INTERFACE_TYPE=None
export MASTER_EXTRA_DISKS_NUMBER=0
export MASTER_EXTRA_DISKS_SIZE=10
export NETWORK_ADAPTER_VMWARE=vmxnet3
export NETWORK_CIDR=192.168.123.0/24
export NETWORK_PLATFORM='Cluster Managed'
export NFS_PV_STORAGE_CLASS=standard
export NFS_SHARES=5
export NFS_SHARE_SIZE=20Gi
export NFS_STORAGE=false
export NON_DEFAULT_PULL_SECRET=false
export OCP_DEPLOYMENT_TYPE=None
export OCP_Z_VERSION=''
export OCS_POST_DEPLOYMENT_TESTS=false
export OCS_VERSION_POST_DEPLOYMENT_TESTS=''
export PREPARE_PROVISIONHOST_SSH_KEY=true
export PROVISION=true
export PROVISIONHOST_DISK_SIZE=40
export PROVISIONING_NETWORK_STATE=Disabled
export REDFISH_NODES_FILE=''
export RP_PROJECT=OCP-EDGE-DEV
export RUN_CUCUSHIFT=false
export SEND_RESULTS_TO_REPORT_PORTAL=false
export SNO_DEPLOYMENT=false
export SYSTEM_PYTHON=/usr/bin/python3
export USE_HTTP_PROXY=false
export VIRT_GPU=false
export VLAN=false
export VMWARE_VERSION=8
export VM_PLATFORM=KVM
export VM_UEFI_FIRMWARE=true
export WORKER_EXTRA_DISKS_NUMBER=0
export WORKER_EXTRA_DISKS_SIZE=200
export OCP_MAJOR_VERSION=${QE_OCP_VERSION%%.*}
export OCP_MINOR_VERSION=${QE_OCP_VERSION#*.}
export CLUSTER_NAME=${HOST%%.*}
export BASE_REPO_DIR=$WORKSPACE/ocp-edge-qe-demo
export VENV=$WORKSPACE/ocp-edge-qe-venv
export OCP_EDGE_DIR=$WORKSPACE/ocp-edge
export TFDEST=$BASE_REPO_DIR/terraform/assisted
export TFSTATE=terraform-assisted.tfstate
export OCM_VAULT_CRED=$QE_SECRETS_DIR/ocm-vault-password
export ROUTE53_VAULT_CRED=$QE_SECRETS_DIR/route53-vault-password
export VAULT_PASSWORD_FILE=$BASE_REPO_DIR/edge_vault_file
export ANSIBLE_CALLBACK_WHITELIST=junit
ARCH=$(uname -m)
OS_MAJOR_VERSION=$(rpm -E '%{rhel}')
SSH_PUB_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
export ARCH OS_MAJOR_VERSION SSH_PUB_KEY
ENVIRONMENT
source "$WORKSPACE/api.env"
git clone "$OCP_EDGE_REPO" "$BASE_REPO_DIR"
git -C "$BASE_REPO_DIR" fetch origin "$OCP_EDGE_REF"
git -C "$BASE_REPO_DIR" checkout --detach "$OCP_EDGE_REF"
git -C "$BASE_REPO_DIR" rev-parse HEAD > "$WORKSPACE/results/ocp-edge-revision.txt"
sudo -n true
test -s "$HOME/.ssh/id_rsa.pub"
for tool in git virsh podman timeout setsid; do command -v "$tool"; done
case "$OS_MAJOR_VERSION" in
    9) python=/usr/bin/python3.12; ansible=ansible==11.9.0 ;;
    8) python=/usr/bin/python3.8; ansible=ansible
       [[ -x "$python" ]] || python=/usr/bin/python3.6 ;;
    *) echo "Unsupported host OS: $OS_MAJOR_VERSION"; exit 1 ;;
esac
test -x "$python"
# This POC starts on a clean, exclusively assigned KVM host.
sudo rm -rf /var/tmp/assisted /root/test_artifacts "$HOME/test_artifacts" "$HOME/kni-assisted-installer-ui-auto"

"$python" -m venv "$VENV"
source "$VENV/bin/activate"
pip install --upgrade pip
pip install "$ansible" netaddr junit_xml objectpath lxml jmespath dnspython pyghmi virtualenv
[[ "$OS_MAJOR_VERSION" != 9 ]] || pip install ansible-core==2.18.8
pip install boto3 libvirt-python pyyaml jinja2 bs4 selinux
cd "$BASE_REPO_DIR"
vars=linchpin-workspace/hooks/ansible/ocp-edge-setup
ansible -i localhost, localhost --connection=local --vault-password-file "$OCM_VAULT_CRED" \
    -m template -a "src=$vars/extravars.yaml dest=$BASE_REPO_DIR/extravars.yaml" \
    -e "@$vars/vault_files/ocp_secrets_ai_saas.yaml" -e "@$vars/extravars.yaml"
if ! command -v terraform; then
    ansible-playbook -e "ansible_python_interpreter=$SYSTEM_PYTHON" -i localhost, \
        --connection=local terraform/terraform_install.yml
fi
cd "$BASE_REPO_DIR/linchpin-workspace"
ansible-playbook -i localhost, -c local hooks/ansible/ocp-edge-setup/download_base_image.yml \
    --vault-password-file "$OCM_VAULT_CRED" -e @hooks/ansible/ocp-edge-setup/vault_files/ocp_secrets_ai_saas.yaml

cd "$TFDEST"
rm -f .terraform.lock.hcl
terraform init
cd "$BASE_REPO_DIR"
export ANSIBLE_FILTER_PLUGINS="$HOME/.ansible/plugins/filter:/usr/share/ansible/plugins/filter:$BASE_REPO_DIR/$vars/filter_plugins"
ansible -i localhost, localhost --connection=local -m template \
    -a "src=$vars/templates/terraform-networks.j2 dest=$TFDEST/terraform.tfvars" \
    -e "@$vars/extravars.yaml" -e "cluster_count=$CLUSTER_COUNT" \
    -e "baremetal_net_ipv6=$BAREMETAL_NET_IPV6" -e "baremetal_net_ipv4=$BAREMETAL_NET_IPV4"
ansible-galaxy collection install community.general:8.6.0 --force
touch "$WORKSPACE/prepared"
REMOTE
