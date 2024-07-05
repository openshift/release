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
HYPERV_IP=10.1.104.3 # "$(cat /var/run/up-hv-ip/uphvip)"
HYPERV_HOST=cnfdr3
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
echo $CL_SEARCH
cat << EOF > $SHARED_DIR/bastion_inventory
[bastion]
${BASTION_IP} ansible_ssh_user=${BASTION_USER} ansible_ssh_common_args="$COMMON_SSH_ARGS" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF

# Check connectivity
ping ${BASTION_IP} -c 10 || true
echo "exit" | ncat ${BASTION_IP} 22 && echo "SSH port is opened"|| echo "status = $?"

MGMT_CLUSTER="cnfdr15"
CLUSTER_NAME="cnfdr16"
MGMT_CLUSTER_API_IP="10.1.104.33"
CLUSTER_API_PORT=6443
CLUSTER_ENV="internalbos"
echo "${CLUSTER_NAME}" > ${ARTIFACT_DIR}/job-cluster

if [[ "$CLUSTER_ENV" != "upstreambil" ]]; then
    BASTION_ENV=false
fi

if $BASTION_ENV; then
# Run on upstream lab with bastion
cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${HYPERV_IP} ansible_host=${HYPERV_IP} ansible_user=kni ansible_ssh_private_key_file="${SSH_PKEY}" ansible_ssh_common_args='${COMMON_SSH_ARGS} -o ProxyCommand="ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -p 22 -W %h:%p -q ${BASTION_USER}@${BASTION_IP}"'
EOF
else
# Run on downstream HV without bastion
cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${HYPERV_IP} ansible_host=${HYPERV_IP} ansible_ssh_user=kni ansible_ssh_common_args="${COMMON_SSH_ARGS}" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF
fi

cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfigs for cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Copy kubeconfig from installer vm
    shell: kcli scp root@${MGMT_CLUSTER}-installer:/root/ocp/auth/kubeconfig /home/kni/.kube/config_${MGMT_CLUSTER}

  - name: Copy kubeconfig from Hypershift directory
    shell: cp /home/kni/hcp-jobs/${CLUSTER_NAME}/out/${CLUSTER_NAME}-kubeadmin-kubeconfig /home/kni/.kube/hcp_config_${CLUSTER_NAME}

  - name: Add skip-tls-verify to mgmt kubeconfig
    replace:
      path: /home/kni/.kube/config_${MGMT_CLUSTER}
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Add skip-tls-verify to HCP kubeconfig
    replace:
      path: /home/kni/.kube/hcp_config_${CLUSTER_NAME}
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Grab the kubeconfig of management cluster
    fetch:
      src: /home/kni/.kube/config_${MGMT_CLUSTER}
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
      replace: "    server: https://${MGMT_CLUSTER_API_IP}:${CLUSTER_API_PORT}"
    delegate_to: localhost

  - name: Add docker auth to enable pulling containers from CI registry
    shell: >-
      oc --kubeconfig=/home/kni/.kube/config_${MGMT_CLUSTER} set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/home/kni/pull-secret.txt

  - name: Add docker auth to enable pulling containers from CI registry for HCP cluster
    shell: >-
      oc --kubeconfig=/home/kni/.kube/hcp_config_${CLUSTER_NAME} set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/home/kni/pull-secret.txt

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

# Copy kubeconfig to hypervisor
echo "Copy kubeconfig to hypervisor"
ssh -i $SSH_PKEY $COMMON_SSH_ARGS kni@${HYPERV_IP} "kcli scp root@${MGMT_CLUSTER}-installer:/root/ocp/auth/kubeconfig /home/kni/${MGMT_CLUSTER}-kubeconfig"

# Copy automation repo to local SHARED_DIR
echo "Copy automation repo to local $SHARED_DIR"
mkdir $SHARED_DIR/repos
ssh -i $SSH_PKEY $COMMON_SSH_ARGS ${BASTION_USER}@${BASTION_IP} \
    "tar --exclude='.git' -czf - -C /home/${BASTION_USER} ansible-automation" | tar -xzf - -C $SHARED_DIR/repos/

# Change the host to hypervisor
echo "Change the host to hypervisor to ${HYPERV_HOST}"
cd $SHARED_DIR/repos/ansible-automation
sed -i "s/- hosts: localhost/- hosts: ${HYPERV_HOST}/g" playbooks/hosted_bm_cluster.yaml
sed -i "s/- hosts: localhost/- hosts: ${HYPERV_HOST}/g" playbooks/remove_bm_cluster.yaml

# Until new image is coming
pip3 install -U jmespath jsonpatch openshift kubernetes

# Run the playbook to remove any cluster that exists now
echo "Run the playbook to remove any cluster that exists now"
ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    playbooks/remove_bm_cluster.yaml \
    -e kubeconfig=/home/kni/${MGMT_CLUSTER}-kubeconfig \
    -e cluster_name=$CLUSTER_NAME \
    -e ansible_host=${HYPERV_IP} -e ansible_ssh_user=kni -e ansible_ssh_private_key_file="${SSH_PKEY}" \
    -e virtual_cluster_deletion=true || true

# Run the playbook to install the cluster
echo "Run the playbook to install the cluster"
status=0
ANSIBLE_LOG_PATH=$ARTIFACT_DIR/ansible.log ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook \
    playbooks/hosted_bm_cluster.yaml \
    -e kubeconfig=/home/kni/${MGMT_CLUSTER}-kubeconfig \
    -e pre_step_mgmt_cluster=false \
    -e hcphost=$CLUSTER_NAME \
    -e virtual_worker_count=2 \
    -e hide_sensitive_log=true \
    -e hostedbm_working_root_dir=/home/kni/hcp-jobs \
    -e tag=$T5CI_VERSION \
    -e ansible_host=${HYPERV_IP} -e ansible_ssh_user=kni -e ansible_ssh_private_key_file="${SSH_PKEY}" \
    -e release=nightly || status=$?

# PROCEED_AFTER_FAILURES is used to allow the pipeline to continue past cluster setup failures for information gathering.
# CNF tests do not require this extra gathering and thus should fail immdiately if the cluster is not available.
# It is intentionally set to a string so that it can be evaluated as a command (either /bin/true or /bin/false)
# in order to provide the desired return code later.
PROCEED_AFTER_FAILURES="false"
if [[ "$T5_JOB_DESC" != "periodic-hcp-cnftests" ]]; then
    PROCEED_AFTER_FAILURES="true"
fi

echo "Run fetch kubeconfig playbook"
ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -vv || eval $PROCEED_AFTER_FAILURES

echo "Run fetching information for clusters"
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/fetch-information.yml -vv || eval $PROCEED_AFTER_FAILURES
echo "Exiting with status ${status}"
# enable for debug, copy raw logs to HV
# scp -i $SSH_PKEY $COMMON_SSH_ARGS $ARTIFACT_DIR/ansible.log kni@${HYPERV_IP}:/tmp/ansible_job-"$(date +%Y-%m-%d-%H-%M)".log
# scp -i $SSH_PKEY $COMMON_SSH_ARGS ${ARTIFACT_DIR}/_job.log kni@${HYPERV_IP}:/tmp/build_job-"$(date +%Y-%m-%d-%H-%M)".log
exit ${status}
