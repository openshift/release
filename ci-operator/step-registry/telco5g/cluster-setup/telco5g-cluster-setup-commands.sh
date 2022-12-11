#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
HYPERV_IP="$(cat /var/run/up-hv-ip/uphvip)"
DSHVIP="$(cat /var/run/ds-hv-ip/dshvip)"
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

KCLI_PARAM=""
if [[ "$PROW_JOB_ID" =~ "nightly" ]]; then
    # In case of running on nightly releases we need to figure out what release exactly to use
    KCLI_PARAM="-P openshift_image=registry.ci.openshift.org/ocp/release:${PROW_JOB_ID/-telco5g/}"
elif [ ! -z $JOB_NAME ]; then
    # In case of regular periodic job
    tmpvar="${JOB_NAME/*nightly-/}"
    ocp_ver="${tmpvar/-e2e-telco5g/}"
    KCLI_PARAM="-P tag=$ocp_ver -P version=nightly"
fi
echo "==========  Running with KCLI_PARAM=$KCLI_PARAM  =========="

# Set environment for jobs to run
INTERNAL=true
INTERNAL_ONLY=true
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
    command: python3 ~/telco5g-lab-deployment/scripts/upstream_cluster_all.py --get-cluster -e $CL_SEARCH
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
IFS=- read -r CLUSTER_NAME CLUSTER_API_IP CLUSTER_API_PORT CLUSTER_ENV <<< "$(cat ${SHARED_DIR}/cluster_name)"
PLAN_NAME="${CLUSTER_NAME}_ci"

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
${DSHVIP} ansible_host=${DSHVIP} ansible_ssh_user=kni ansible_ssh_common_args="${COMMON_SSH_ARGS}" ansible_ssh_private_key_file="${SSH_PKEY}"
EOF

fi
echo "#############################################################################..."
echo "========  Deploying plan $PLAN_NAME on cluster $CLUSTER_NAME $(if $BASTION_ENV; then echo "with a bastion"; fi)  ========"
echo "#############################################################################..."

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
  - name: Remove last run
    shell: kcli delete plan --yes ${PLAN_NAME}
    ignore_errors: yes
  - name: Remove lock file
    file:
      path: /home/kni/us_${CLUSTER_NAME}_ready.txt
      state: absent
  - name: Run deployment
    shell: kcli create plan --force --paramfile /home/kni/params_${CLUSTER_NAME}.yaml ${PLAN_NAME} $KCLI_PARAM
    args:
      chdir: ~/kcli-openshift4-baremetal
  - name: Try to grab file to see install finished
    shell: >-
      kcli scp root@${CLUSTER_NAME}-installer:/root/cluster_ready.txt /home/kni/us_${CLUSTER_NAME}_ready.txt &&
      ls /home/kni/us_${CLUSTER_NAME}_ready.txt
    register: result
    until: result is success
    retries: 150
    delay: 60
  - name: Check if successful
    stat: path=/home/kni/us_${CLUSTER_NAME}_ready.txt
    register: ready
  - name: Fail if file was not there
    fail:
      msg: Installation not finished yet
    when: ready.stat.exists == False
EOF

cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfig for cluster
  hosts: hypervisor
  gather_facts: false
  tasks:
  - name: Copy kubeconfig from installer vm
    shell: kcli scp root@${CLUSTER_NAME}-installer:/root/ocp/auth/kubeconfig /home/kni/.kube/config_${CLUSTER_NAME}
  - name: Add skip-tls-verify to kubeconfig
    lineinfile:
      path: /home/kni/.kube/config_${CLUSTER_NAME}
      regexp: '    certificate-authority-data:'
      line: '    insecure-skip-tls-verify: true'
  - name: Grab the kubeconfig
    fetch:
      src: /home/kni/.kube/config_${CLUSTER_NAME}
      dest: $SHARED_DIR/kubeconfig
      flat: yes
  - name: Modify local copy of kubeconfig
    lineinfile:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server: https://api.*'
      line: "    server: https://${CLUSTER_API_IP}:${CLUSTER_API_PORT}"
    delegate_to: localhost
EOF

ansible-playbook -i $SHARED_DIR/inventory ~/ocp-install.yml -vv
ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -vv
