#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# enable for debug
# exec &> >(tee -i -a ${ARTIFACT_DIR}/_job.log )
# set -x

echo "************ telco cluster setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

date +%s > $SHARED_DIR/start_time

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"

# Use same version for mgmt and guest clusters for now
# Switch to different if there is a problem
MGMT_VERSION=$T5CI_VERSION

COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

source $SHARED_DIR/main.env
echo "==========  Running with KCLI_PARAM=$KCLI_PARAM =========="

# Set environment for jobs to run
INTERNAL=true
INTERNAL_ONLY=true
# If the job trigger is "periodic" or "nightly" or the repository owner is "openshift-kni",
# use the upstream cluster to run the job.
if [[ "$T5_JOB_TRIGGER" == "periodic" ]] || [[ "$T5_JOB_TRIGGER" == "nightly" ]] || [[ "$REPO_OWNER" == "openshift-kni" ]]; then
    INTERNAL=false
    INTERNAL_ONLY=false
else
    # Run other jobs on any cluster
    INTERNAL_ONLY=false
fi
# Whether to use the bastion environment
BASTION_ENV=true
# Environment - US lab, DS lab or any
CL_SEARCH="upstreambil"

if $INTERNAL_ONLY && $INTERNAL; then
    CL_SEARCH="internalbos"
elif $INTERNAL; then
    CL_SEARCH="any"
fi

if [[ "$JOB_NAME" == *"e2e-telcov10n-functional-hcp-cnf"* ]]; then
    INTERNAL=true
    INTERNAL_ONLY=true
# Using internalbos temporarily 
    CL_SEARCH="computeqe"
    HOSTS_NUMBER=" --number 2"
fi

echo $CL_SEARCH
cat << EOF > $SHARED_DIR/bastion_inventory
[bastion]
${BASTION_IP} ansible_ssh_user=${BASTION_USER} ansible_ssh_common_args="$COMMON_SSH_ARGS" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF

# Check connectivity
ping ${BASTION_IP} -c 10 || true
echo "exit" | ncat ${BASTION_IP} 22 && echo "SSH port is opened"|| echo "status = $?"

# Choose for hypershift hosts for "sno" or "1b1v" - 1 baremetal host
ADDITIONAL_ARG="-e $CL_SEARCH --topology 1b1v --topology sno ${HOSTS_NUMBER-}"

cat << EOF > $SHARED_DIR/get-cluster-name.yml
---
- name: Find a cluster to run job
  hosts: bastion
  gather_facts: false
  tasks:
  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      timeout: 125
      connect_timeout: 90
    register: sshresult
    until: sshresult is success
    retries: 15
    delay: 2
  - name: Discover cluster to run job
    command: python3 ~/telco5g-lab-deployment/scripts/upstream_cluster_all.py --get-cluster $ADDITIONAL_ARG
    register: cluster
    environment:
      JOB_NAME: ${JOB_NAME:-'unknown'}
  - name: Create a file with cluster name
    shell: echo "{{ cluster.stdout }}" > $SHARED_DIR/cluster_name
    delegate_to: localhost
EOF

ansible-playbook -i $SHARED_DIR/bastion_inventory $SHARED_DIR/get-cluster-name.yml -vvvv
# Get all required variables - cluster name, API IP, port, environment
# shellcheck disable=SC2046,SC2034
IFS=- read -r CLUSTER_NAME CLUSTER_API_IP CLUSTER_API_PORT CLUSTER_HV_IP CLUSTER_ENV ADD_BM_HOST <<< "$(cat ${SHARED_DIR}/cluster_name)"
echo "${CLUSTER_NAME}" > ${ARTIFACT_DIR}/job-cluster
SNO_NAME=sno-${CLUSTER_NAME}
# if ADD_BM_HOST is not empty, include it in release
RELEASE_ADD=""
if [[ -n "$ADD_BM_HOST" ]]; then
    RELEASE_ADD="--release-cluster $ADD_BM_HOST"
fi

cat << EOF > $SHARED_DIR/release-cluster.yml
---
- name: Release cluster $CLUSTER_NAME
  hosts: bastion
  gather_facts: false
  tasks:

  - name: Release cluster from job
    command: python3 ~/telco5g-lab-deployment/scripts/upstream_cluster_all.py --release-cluster $CLUSTER_NAME $RELEASE_ADD
EOF

if [[ "$CLUSTER_ENV" != "upstreambil" ]]; then
    BASTION_ENV=false
fi

# Copy automation repo to local SHARED_DIR
echo "Copy automation repo to local $SHARED_DIR"
mkdir $SHARED_DIR/repos
ssh -i $SSH_PKEY $COMMON_SSH_ARGS ${BASTION_USER}@${BASTION_IP} \
    "tar --exclude='.git' -czf - -C /home/${BASTION_USER} ansible-automation" | tar -xzf - -C $SHARED_DIR/repos/

cd $SHARED_DIR/repos/ansible-automation

# Change the host to hypervisor
echo "Change the host from localhost to hypervisor"
sed -i "s/- hosts: localhost/- hosts: hypervisor/g" playbooks/hosted_bm_cluster.yaml

# shellcheck disable=SC1083
HYPERV_HOST="$(grep -h "${CLUSTER_HV_IP} " inventory/* | awk {'print $1'})"
# In BOS2 we use a regular dnsmasq, not the NetworkManager based
# Use ProxyJump if using BOS2
if $BASTION_ENV; then
    cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${HYPERV_HOST} ansible_host=${CLUSTER_HV_IP} ansible_user=kni ansible_ssh_private_key_file="${SSH_PKEY}" ansible_ssh_common_args='${COMMON_SSH_ARGS} -o ProxyCommand="ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -p 22 -W %h:%p -q ${BASTION_USER}@${BASTION_IP}"'
EOF
else
    cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${HYPERV_HOST} ansible_host=${CLUSTER_HV_IP} ansible_ssh_user=kni ansible_ssh_common_args="${COMMON_SSH_ARGS}" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF
fi

data=$(ansible -i $SHARED_DIR/inventory hypervisor -m shell -a "host $SNO_NAME" | grep address)

SNO_IP=$(echo $data | sed "s/.*address //g")
SNO_FQDN=$(echo $data | cut -d" " -f1)
SNO_DOMAIN=$(echo $SNO_FQDN | cut -d"." -f2-)

# Create a playbook to remove existing SNO
cat << EOF > $SHARED_DIR/delete-sno.yml
---
- name: Delete existing SNO
  hosts: hypervisor
  gather_facts: false
  tasks:

    - name: Remove existing SNO
      include_role:
        name: virtual_sno
        tasks_from: deletion.yml
      vars:
        vsno_name: $SNO_NAME
        vsno_domain_name: $SNO_DOMAIN

EOF

cat << EOF > $SHARED_DIR/destroy-cluster.yml
---
- name: Delete cluster if exists
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Remove last run for ${CLUSTER_NAME}_ci
    shell: |
        kcli delete plan --yes ${CLUSTER_NAME}_ci
        kcli delete plan --yes ${CLUSTER_NAME}
    ignore_errors: yes

  - name: Remove last run for ${ADD_BM_HOST:-empty}_ci
    shell: |
        kcli delete plan --yes ${ADD_BM_HOST:-empty}_ci
        kcli delete plan --yes ${ADD_BM_HOST:-empty}
    ignore_errors: yes

EOF



cat << EOF > ~/fetch-information.yml
---
- name: Fetch information about HCP cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Get cluster version
    shell: oc --kubeconfig=/home/kni/.kube/hcp_config_${CLUSTER_NAME} get clusterversion

  - name: Get cluster operators objects
    shell: oc --kubeconfig=/home/kni/.kube/hcp_config_${CLUSTER_NAME} get co

  - name: Get nodes
    shell: oc --kubeconfig=/home/kni/.kube/hcp_config_${CLUSTER_NAME} get node

EOF

cat << EOF > ~/freeip.yml
---
- name: Allocate free ip
  hosts: hypervisor
  gather_facts: false
  tasks:

    - name: Get IP
      include_role:
        name: freeip
      vars:
        get_by_range: ${CLUSTER_HV_IP%.*}

EOF

# TODO: add this to image build
pip3 install dnspython netaddr
ansible-galaxy collection install -r ansible-requirements.yaml


cp $SHARED_DIR/inventory inventory/billerica_inventory

# Run the playbook to remove SNO
echo "Run the playbook to remove SNO management cluster"
ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    $SHARED_DIR/delete-sno.yml

echo "Run the playbook to remove possible kcli clusters"
ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    $SHARED_DIR/destroy-cluster.yml

if $BASTION_ENV; then
    PLAYBOOK_ARGS=" -e hostedbm_inject_dns=true "
    SNO_CLUSTER_API_PORT="64${SNO_IP##*.}"  # "64" and last octet of SNO_IP address
else
    PLAYBOOK_ARGS=" -e hostedbm_inject_dns=false "
    SNO_CLUSTER_API_PORT="6443"
fi

if [[ "$T5CI_VERSION" == "4.21" ]] || [[ "$T5CI_VERSION" == "4.22" ]]; then
    PLAYBOOK_ARGS+=" -e vsno_custom_source=registry.redhat.io/redhat/redhat-operator-index:v4.20"
    PLAYBOOK_ARGS+=" -e hcp_custom_source=registry.redhat.io/redhat/redhat-operator-index:v4.20"
fi

cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfigs for cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Copy kubeconfig for management cluster on SNO
    shell: cp /home/kni/hcp-jobs/${SNO_NAME}/config/auth/kubeconfig /home/kni/.kube/config_${SNO_NAME}

  - name: Copy kubeconfig from Hypershift directory
    shell: cp /home/kni/hcp-jobs/${CLUSTER_NAME}/out/${CLUSTER_NAME}-kubeadmin-kubeconfig /home/kni/.kube/hcp_config_${CLUSTER_NAME}

  - name: Add skip-tls-verify to mgmt kubeconfig
    replace:
      path: /home/kni/.kube/config_${SNO_NAME}
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Add skip-tls-verify to HCP kubeconfig
    replace:
      path: /home/kni/.kube/hcp_config_${CLUSTER_NAME}
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Grab the kubeconfig of management cluster
    fetch:
      src: /home/kni/.kube/config_${SNO_NAME}
      dest: $SHARED_DIR/mgmt-kubeconfig
      flat: yes

  - name: Grab the Hypershift kubeconfig
    fetch:
      src: /home/kni/.kube/hcp_config_${CLUSTER_NAME}
      dest: $SHARED_DIR/kubeconfig
      flat: yes

  - name: Modify local copy of mgmt kubeconfig
    replace:
      path: $SHARED_DIR/mgmt-kubeconfig
      regexp: '    server: https://api.*'
      replace: "    server: https://${SNO_IP}:${SNO_CLUSTER_API_PORT}"
    delegate_to: localhost

  - name: Modify local copy of HCP kubeconfig
    replace:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server: https://(.*):6443'
      replace: '    server: https://${CLUSTER_API_IP}:${CLUSTER_API_PORT}'
    delegate_to: localhost

  - name: Add docker auth to enable pulling containers from CI registry
    shell: >-
      oc --kubeconfig=/home/kni/.kube/config_${SNO_NAME} set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/home/kni/pull-secret.txt

  - name: Add docker auth to enable pulling containers from CI registry for HCP cluster
    shell: >-
      oc --kubeconfig=/home/kni/.kube/hcp_config_${CLUSTER_NAME} set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/home/kni/pull-secret.txt

  - name: Patching hostedcluster to disable all default sources
    shell: >-
      oc --kubeconfig=/home/kni/.kube/config_${SNO_NAME} patch hostedcluster ${CLUSTER_NAME} -n clusters --type=merge -p '{"spec": {"configuration": {"operatorhub": {"disableAllDefaultSources": true}}}}'

EOF

if [[ "$JOB_NAME" == *"e2e-telcov10n-functional-hcp-cnf-nrop"* ]]; then
    PLAYBOOK_ARGS+=" -e add_bm_host=$ADD_BM_HOST"
fi
if [[ "$JOB_NAME" != *"e2e-telcov10n-functional-hcp-cnf"* ]]; then
    PLAYBOOK_ARGS+=" -e image_override=quay.io/hypershift/hypershift-operator:latest "
fi
# Run the playbook to install the cluster
echo "Run the playbook to install the cluster"
status=0

ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    playbooks/sno_hcp_e2e.yml \
    -e hcphost=$CLUSTER_NAME \
    -e vsno_name=$SNO_NAME \
    -e vsno_ip=$SNO_IP \
    -e vsno_add_nm_hosts=false \
    -e sno_tag=$MGMT_VERSION \
    -e vsno_wait_minutes=150 \
    -e vsno_release=$T5CI_JOB_MGMT_RELEASE_TYPE \
    -e hcp_tag=$T5CI_VERSION \
    -e hcp_release=$T5CI_JOB_HCP_RELEASE_TYPE $PLAYBOOK_ARGS || status=$?

# PROCEED_AFTER_FAILURES is used to allow the pipeline to continue past cluster setup failures for information gathering.
# CNF tests do not require this extra gathering and thus should fail immdiately if the cluster is not available.
# It is intentionally set to a string so that it can be evaluated as a command (either /bin/true or /bin/false)
# in order to provide the desired return code later.
PROCEED_AFTER_FAILURES="false"
if [[ "$T5_JOB_DESC" != "periodic-hcp-cnftests" ]]; then
    PROCEED_AFTER_FAILURES="true"
fi

if [[ "$status" == "0" ]]; then
    echo "Run fetch kubeconfig playbook"
    ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -vv || eval $PROCEED_AFTER_FAILURES

    echo "Run fetching information for clusters"
    ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/fetch-information.yml -vv || eval $PROCEED_AFTER_FAILURES
fi

echo "Exiting with status ${status}"
exit ${status}
