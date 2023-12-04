#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

date +%s > $SHARED_DIR/start_time

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
HYPERV_IP="$(cat /var/run/up-hv-ip/uphvip)"
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

# Clusters to use for cnf-tests, and to exclude from selection in other jobs
PREPARED_CLUSTER=("cnfdu1" "cnfdu3")

source $SHARED_DIR/main.env
echo "==========  Running with SNO_PARAM=$SNO_PARAM =========="

# Set environment for jobs to run
INTERNAL=true
INTERNAL_ONLY=true
# Run cnftests periodic and nightly job on Upstream cluster
if [[ "$T5_JOB_TRIGGER" == "periodic" ]] || [[ "$T5_JOB_TRIGGER" == "nightly" ]]; then
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

cat << EOF > $SHARED_DIR/bastion_inventory
[bastion]
${BASTION_IP} ansible_ssh_user=centos ansible_ssh_common_args="$COMMON_SSH_ARGS" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF

ADDITIONAL_ARG="-e $CL_SEARCH --exclude ${PREPARED_CLUSTER[0]} --exclude ${PREPARED_CLUSTER[1]} --topology sno "

cat << EOF > $SHARED_DIR/get-cluster-name.yml
---
- name: Grab and run kcli to install openshift cluster
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

# Check connectivity
ping ${BASTION_IP} -c 10 || true
echo "exit" | curl telnet://${BASTION_IP}:22 && echo "SSH port is opened"|| echo "status = $?"

ansible-playbook -i $SHARED_DIR/bastion_inventory $SHARED_DIR/get-cluster-name.yml -vvvv
# Get all required variables - cluster name, API IP, port, environment
# shellcheck disable=SC2046,SC2034
IFS=- read -r CLUSTER_NAME CLUSTER_API_IP CLUSTER_API_PORT CLUSTER_HV_IP CLUSTER_ENV <<< "$(cat ${SHARED_DIR}/cluster_name)"
echo "${CLUSTER_NAME}" > ${ARTIFACT_DIR}/job-cluster

cat << EOF > $SHARED_DIR/release-cluster.yml
---
- name: Release cluster $CLUSTER_NAME
  hosts: bastion
  gather_facts: false
  tasks:

  - name: Release cluster from job
    command: python3 ~/telco5g-lab-deployment/scripts/upstream_cluster_all.py --release-cluster $CLUSTER_NAME
EOF

if [[ "$CLUSTER_ENV" != "upstreambil" ]]; then
    BASTION_ENV=false
fi

if $BASTION_ENV; then
# Run on upstream lab with bastion
cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${HYPERV_IP} ansible_host=${HYPERV_IP} ansible_user=kni ansible_ssh_private_key_file="${SSH_PKEY}" ansible_ssh_common_args='${COMMON_SSH_ARGS} -o ProxyCommand="ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -p 22 -W %h:%p -q centos@${BASTION_IP}"'
EOF

else
# Run on downstream cnfdc1 without bastion
cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${CLUSTER_HV_IP} ansible_host=${CLUSTER_HV_IP} ansible_ssh_user=kni ansible_ssh_common_args="${COMMON_SSH_ARGS}" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF

fi
echo "#############################################################################..."
echo "========  Deploying plan SNO on cluster $CLUSTER_NAME $(if $BASTION_ENV; then echo "with a bastion"; fi)  ========"
echo "#############################################################################..."

WORK_DIR="/home/kni/ag-sno/${CLUSTER_NAME}-${T5CI_VERSION}-nightly"
# Start the deployment
cat << EOF > ~/ocp-install.yml
---
- name: Grab and run kcli to install openshift cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300

  - name: Remove previous log file
    file:
      path: /tmp/${CLUSTER_NAME}_sno_ag.log
      state: absent

  - name: Run deployment
    shell: >-
        ./scripts/sno_ag.py $SNO_PARAM --host ${CLUSTER_NAME} --debug --wait
        --host-ip ${HYPERV_IP} --registry --reset-bmc
        -L /tmp/${CLUSTER_NAME}_sno_ci.log 2>&1 > /tmp/${CLUSTER_NAME}_sno_ag.log
    args:
      chdir: /home/kni/telco5g-lab-deployment
    async: 5500
    poll: 0
    register: sno_deploy
    ignore_errors: true

  - name: Check on deployment
    async_status:
        jid: "{{ sno_deploy.ansible_job_id }}"
    register: job_result
    until: job_result.finished
    retries: 90
    delay: 60
    ignore_errors: true

  - name: Grab the log from HV to artifacts
    fetch:
      src: "{{ item.src }}"
      dest: "{{ item.dest }}"
      flat: yes
    loop:
      - src: /tmp/${CLUSTER_NAME}_sno_ag.log
        dest: ${ARTIFACT_DIR}/openshift-install.log
      - src: /tmp/${CLUSTER_NAME}_sno_ci.log
        dest: ${ARTIFACT_DIR}/sno-script.log
    ignore_errors: true

  - name: Set fact if deployment passed
    set_fact:
      deploy_failed: false

  - name: Set fact if deployment failed
    set_fact:
      deploy_failed: true
    when:
      - (job_result.failed | bool) or (sno_deploy.failed | bool)

  - name: Show last logs from cloud init if failed
    shell: tail -100 /tmp/${CLUSTER_NAME}_sno_ag.log
    when: deploy_failed | bool
    ignore_errors: true

  - name: Fail if deployment did not finish
    fail:
      msg: Installation not finished yet
    when: job_result.failed | bool

  - name: Fail if deployment failed
    fail:
      msg: Installation has failed
    when: sno_deploy.failed | bool

EOF

cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfig for cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Add skip-tls-verify to kubeconfig
    replace:
      path: ${WORK_DIR}/auth/kubeconfig
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Grab the kubeconfig
    fetch:
      src: ${WORK_DIR}/auth/kubeconfig
      dest: $SHARED_DIR/kubeconfig
      flat: true

  - name: Modify local copy of kubeconfig
    replace:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server: https://api.*'
      replace: "    server: https://${CLUSTER_API_IP}:${CLUSTER_API_PORT}"
    delegate_to: localhost

  - name: Add docker auth to enable pulling containers from CI registry
    shell: >-
      oc --kubeconfig=${WORK_DIR}/auth/kubeconfig set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/home/kni/pull-secret.txt

EOF

cat << EOF > ~/fetch-information.yml
---
- name: Fetch information about cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Get cluster version
    shell: oc --kubeconfig=${WORK_DIR}/auth/kubeconfig get clusterversion

  - name: Get bmh objects
    shell: oc --kubeconfig=${WORK_DIR}/auth/kubeconfig get bmh -A

  - name: Get nodes
    shell: oc --kubeconfig=${WORK_DIR}/auth/kubeconfig get node
EOF

cat << EOF > ~/check-cluster.yml
---
- name: Check if cluster is ready
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Check if cluster is available
    shell: oc --kubeconfig=${WORK_DIR}/auth/kubeconfig get clusterversion -o=jsonpath='{.items[0].status.conditions[?(@.type=='\''Available'\'')].status}'
    register: ready_check

  - name: Check for errors in cluster deployment
    shell: oc --kubeconfig=${WORK_DIR}/auth/kubeconfig get clusterversion
    register: error_check

  - name: Fail if deployment failed
    fail:
      msg: Installation has failed
    when: "'True' not in ready_check.stdout or 'Error while reconciling' in error_check.stdout"

EOF

#Set status and run playbooks
status=0
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/ocp-install.yml -vv || status=$?
ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -vv || true
sleep 300  # Wait for cluster to be ready after a reboot
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/fetch-information.yml -vv || true
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/check-cluster.yml -vv
exit ${status}
