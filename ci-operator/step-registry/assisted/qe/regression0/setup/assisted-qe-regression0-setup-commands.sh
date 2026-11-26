#!/bin/bash
set -euo pipefail
umask 077

# Boskos owns this host for all pre/test/post steps. Jenkins does not use Boskos:
# an administrator must first remove each enabled host from ALL Jenkins users.
host=${ASSISTED_QE_HOST:?No Boskos host lease}
[[ "$host" =~ ^sealusa5[0-3]\.kni\.eng\.rdu2\.dc\.redhat\.com$ ]]
grep -Fxq "$host" /var/run/assisted-qe/enabled-hosts
[[ "$QE_CI_REF" =~ ^[0-9a-f]{40}$ && "$QE_EDGE_REF" =~ ^[0-9a-f]{40}$ ]]
[[ "$QE_OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]
[[ "$QE_PUBLISH_RESULTS" == true || "$QE_PUBLISH_RESULTS" == false ]]

# Only connection metadata and executable helpers go in SHARED_DIR, no vaults.
cat > "${SHARED_DIR}/qe-ssh.sh" <<'HELPER'
set -euo pipefail
umask 077
key=$(mktemp)
cp /var/run/assisted-qe/ssh-privatekey "$key"
chmod 600 "$key"
trap 'rm -f "$key"' EXIT
ssh_options=(-i "$key" -o BatchMode=yes -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/var/run/assisted-qe/known_hosts
    -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
host=$(cat "${SHARED_DIR}/qe-host")
# Commands are constructed locally with quoted, validated paths.
# shellcheck disable=SC2029
qe_ssh() { ssh "${ssh_options[@]}" "kni@${host}" "$@"; }
qe_stop() {
    local work command
    work=$(cat "${SHARED_DIR}/qe-workspace")
    [[ "$work" =~ ^/home/kni/prow-regression0/run\.[[:alnum:]]+$ ]]
    printf -v command 'bash -s -- %q' "$work"
    qe_ssh "$command" <<'STOP'
set -euo pipefail
work=$1
if [[ -f "$work/active.pid" ]]; then
    read -r pid < "$work/active.pid"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]
    if kill -0 "$pid" 2>/dev/null; then
        # Refuse to kill a recycled PID unrelated to this run.
        tr '\0' ' ' < "/proc/$pid/cmdline" | grep -F "$work/" > /dev/null
        sudo -n kill -TERM -- "-$pid"
        sleep 5
        sudo -n kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    rm -f "$work/active.pid"
fi
STOP
}
qe_remote() {
    local phase=$1 duration=$2 work command rc=0
    work=$(cat "${SHARED_DIR}/qe-workspace") || return
    [[ "$work" =~ ^/home/kni/prow-regression0/run\.[[:alnum:]]+$ ]] || return 1
    # Keep downstream logs on the host/Datahub, never in public Prow artifacts.
    qe_ssh "umask 077; cat > '$work/$phase.sh'" <<EOF || return
#!/bin/bash
set -euo pipefail
cd '$work'
source ./job.env
$(cat)
EOF
    printf -v command 'bash -s -- %q %q %q' "$work" "$phase" "$duration"
    qe_ssh "$command" <<'SUPERVISOR' || rc=$?
set -euo pipefail
cd "$1"
mkdir -p logs
# A process group and a host-side deadline also protect against pod/SSH loss.
setsid timeout --signal=TERM --kill-after=30s "$3" bash "$1/$2.sh" > "logs/$2.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > active.pid
status=0
wait "$pid" || status=$?
rm -f active.pid
exit "$status"
SUPERVISOR
    echo "${phase}: exit ${rc}; full logs remain on the host/Datahub."
    return "$rc"
}
HELPER
printf '%s\n' "$host" > "${SHARED_DIR}/qe-host"
source "${SHARED_DIR}/qe-ssh.sh"
work=$(qe_ssh 'umask 077; mkdir -p /home/kni/prow-regression0; mktemp -d /home/kni/prow-regression0/run.XXXXXXXX')
[[ "$work" =~ ^/home/kni/prow-regression0/run\.[[:alnum:]]+$ ]]
printf '%s\n' "$work" > "${SHARED_DIR}/qe-workspace"

# Snapshot of the 5.0 regression-stage-0 profile + Groovy parameter defaults.
# See README.md for the source revisions and deliberately changed behavior.
cat > "${SHARED_DIR}/qe-job.env" <<'DEFAULTS'
export ADD_ADDITIONAL_TRUST_BUNDLE=false
export ADD_PROVISIONHOST=false
export ADVANCED_NETWORKING=false
export ASSISTED_API_ENDPOINT=https://api.stage.openshift.com
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
export ASSISTED_FUNCTIONAL_API_TESTS_PARALLEL=3
export ASSISTED_IMAGE_SERVICE_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-image-service:latest
export ASSISTED_INSTALLER_AGENT_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-installer-agent:latest
export ASSISTED_INSTALLER_CONTROLLER_COMPONENT_IMAGE=quay.io/edge-infrastructure/assisted-installer-controller:latest
export ASSISTED_INSTALLER_UI=''
export ASSISTED_LOCAL_REGISTRY_INSTALL=false
export ASSISTED_MINIMAL_ISO=false
export ASSISTED_OCP_NETWORK_CONFIGURATION=Default
export ASSISTED_POLARION_TESTRUN_ID=OS-20260705-1423
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
export ASSISTED_TEST_INFRA_BRANCH=master
export ASSISTED_TEST_INFRA_MARKER=regression0
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
export BASE_DOMAIN=qe.lab.redhat.com
export BOND=false
export CARBON_TEST_REPORTING=false
export CLEAN_WORKSPACE=true
export CLUSTER_COUNT=1
export CPU_ARCHITECTURE=x86_64
export CYPRESS_GREPTAG=''
export DEPLOY_ASSISTED_ON=None
export DEPLOY_MASTER_COUNT=3
export DEPLOY_WORKER_COUNT=2
export DISCONNECTED_INSTALL=false
export DISK_ENABLE_UUID_VMWARE=TRUE
export DUAL_STACK_PATCH=false
export ENABLE_IMAGE_REGISTRY_STORAGE=false
export FACET_DOWNSTREAM_BRANCH=master
export FACET_DOWNSTREAM_REPO=https://gitlab.cee.redhat.com/ocp-edge-qe/kni-assisted-installer-auto.git
export HTTP_AUTHENTICATED_PROXY_USE=false
export IPV4_RANGE_END=150
export IPV4_RANGE_START=50
export KNI_ASSISTED_INSTALLER_AUTO_BRANCH=master
export KNI_ASSISTED_INSTALLER_AUTO_REPO=https://gitlab.cee.redhat.com/ocp-edge-qe/kni-assisted-installer-auto.git
export MANAGEMENT_INTERFACE_TYPE=None
export MASTER_DISK_SIZE=120
export MASTER_EXTRA_DISKS_NUMBER=0
export MASTER_EXTRA_DISKS_SIZE=10
export MASTER_MEMORY=32768
export MASTER_VCPUS=16
export NETWORK_ADAPTER_VMWARE=vmxnet3
export NETWORK_CIDR=192.168.123.0/24
export NETWORK_PLATFORM='Cluster Managed'
export NETWORK_TYPE=OVNKubernetes
export NFS_PV_STORAGE_CLASS=standard
export NFS_SHARES=5
export NFS_SHARE_SIZE=20Gi
export NFS_STORAGE=false
export NON_DEFAULT_PULL_SECRET=false
export OCM_USER=assisted-installer-qe-ci2
export OCP_DEPLOYMENT_TYPE=None
export OCP_Z_VERSION=''
export OCS_POST_DEPLOYMENT_TESTS=false
export OCS_VERSION_POST_DEPLOYMENT_TESTS=''
export PIPELINE_BRANCH=master
export PIPELINE_REPO=https://gitlab.cee.redhat.com/ocp-edge-qe/ocp-edge.git
export PREPARE_PROVISIONHOST_SSH_KEY=true
export PROVISION=true
export PROVISIONHOST_DISK_SIZE=40
export PROVISIONING_NETWORK_STATE=Disabled
export PROVISION_MASTER_COUNT=3
export PROVISION_WORKER_COUNT=2
export REDFISH_NODES_FILE=''
export RP_PROJECT=OCP-EDGE-DEV
export RUN_CUCUSHIFT=false
export SECOND_OCM_USER_FOR_AUTH_TESTS=talhil-aiqe1-u2
export SEND_RESULTS_TO_REPORT_PORTAL=true
export SNO_DEPLOYMENT=false
export SYSTEM_PYTHON=/usr/bin/python3
export USE_HTTP_PROXY=false
export VIRT_GPU=false
export VLAN=false
export VMWARE_VERSION=8
export VM_PLATFORM=KVM
export VM_UEFI_FIRMWARE=true
export WORKER_DISK_SIZE=120
export WORKER_EXTRA_DISKS_NUMBER=0
export WORKER_EXTRA_DISKS_SIZE=200
export WORKER_MEMORY=16384
export WORKER_VCPUS=8
DEFAULTS
{
    printf 'export WORKSPACE=%q\n' "$work"
    printf 'export HOST=%q\n' "$host"
    printf 'export CLUSTER_NAME=%q\n' "${host%%.*}"
    printf 'export OCP_MAJOR_VERSION=%q\n' "${QE_OCP_VERSION%.*}"
    printf 'export OCP_MINOR_VERSION=%q\n' "${QE_OCP_VERSION#*.}"
    printf 'export OPENSHIFT_RELEASE_IMAGE=%q\n' "${RELEASE_IMAGE_LATEST:?}"
    printf 'export QE_CI_REF=%q\n' "$QE_CI_REF"
    printf 'export QE_EDGE_REF=%q\n' "$QE_EDGE_REF"
    printf 'export QE_PUBLISH_RESULTS=%q\n' "$QE_PUBLISH_RESULTS"
    printf 'export PROFILE_NAME=%q\n' 'assisted-saas-phase2-api-test-regression-stage-0'
    printf 'export JOB_NAME=%q\n' "${JOB_NAME:?}"
    printf 'export BUILD_NUMBER=%q\n' "${BUILD_ID:?}"
    printf 'export BUILD_URL=%q\n' "https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/${JOB_NAME}/${BUILD_ID}"
} >> "${SHARED_DIR}/qe-job.env"
cat >> "${SHARED_DIR}/qe-job.env" <<'ENVIRONMENT'
export VENV=$WORKSPACE/ocp-edge-qe-venv
export OCP_EDGE_DIR=$WORKSPACE/ocp-edge
export BASE_REPO_DIR=$WORKSPACE/ocp-edge-qe-demo
export TFDEST=$BASE_REPO_DIR/terraform/assisted
export TFSTATE=terraform-assisted.tfstate
export OCM_VAULT_CRED=$WORKSPACE/ocm-vault-password
export ROUTE53_VAULT_CRED=$WORKSPACE/route53-vault-password
export VAULT_PASSWORD_FILE=$BASE_REPO_DIR/edge_vault_file
export ANSIBLE_CALLBACK_WHITELIST=junit
export ARCH=$(uname -m)
export OS_MAJOR_VERSION=$(rpm -E '%{rhel}')
export SSH_PUB_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
ENVIRONMENT
qe_ssh "umask 077; cat > '$work/job.env'" < "${SHARED_DIR}/qe-job.env"
for vault in ocm-vault-password route53-vault-password; do
    qe_ssh "umask 077; cat > '$work/$vault'" < "/var/run/assisted-qe/$vault"
done

qe_remote setup 55m <<'REMOTE'
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
# Host GitLab access and corporate CA trust are prerequisites, as with Jenkins.
git clone https://gitlab.cee.redhat.com/ocp-edge-qe/ocp-edge-ci.git "$WORKSPACE/ocp-edge-ci"
git -C "$WORKSPACE/ocp-edge-ci" checkout --detach "$QE_CI_REF"
git clone "$PIPELINE_REPO" "$BASE_REPO_DIR"
git -C "$BASE_REPO_DIR" checkout --detach "$QE_EDGE_REF"
printf 'ocp-edge-ci %s\nocp-edge %s\n' "$QE_CI_REF" "$QE_EDGE_REF" > revisions.txt

# The profile's Infra/cleanup-all-terraform precedes the Groovy Init stage.
bash "$WORKSPACE/ocp-edge-ci/jenkins/jobs/utils/clean_all_virsh_resources.sh"
sudo rm -rf /var/tmp/assisted /root/test_artifacts "$HOME/test_artifacts" "$HOME/kni-assisted-installer-ui-auto"

"$python" -m venv "$VENV"
source "$VENV/bin/activate"
pip install --upgrade pip
pip install "$ansible" netaddr junit_xml objectpath lxml jmespath dnspython pyghmi virtualenv \
    carbon_polarion_plugin@git+https://gitlab.cee.redhat.com/ccit/carbon_polarion_plugin.git \
    carbon_rppreproc_plugin@git+https://gitlab.cee.redhat.com/ccit/carbon_rppreproc_plugin.git
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
