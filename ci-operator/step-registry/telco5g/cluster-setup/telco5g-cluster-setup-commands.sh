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
echo "==========  Running with KCLI_PARAM=$KCLI_PARAM =========="

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

ADDITIONAL_ARG=""
# default to the first cluster in the array, unless 4.16
if [[ "$T5_JOB_DESC" == "periodic-cnftests" ]]; then
    ADDITIONAL_ARG="--cluster-name ${PREPARED_CLUSTER[0]} --force"
    if [[ "$T5CI_VERSION" == "4.16" ]]; then
        ADDITIONAL_ARG="--cluster-name ${PREPARED_CLUSTER[1]} --force"
    fi
else
    ADDITIONAL_ARG="-e $CL_SEARCH --exclude ${PREPARED_CLUSTER[0]} --exclude ${PREPARED_CLUSTER[1]}"
fi
# Choose topology for different job types:
# Run periodic cnftests job with 2 baremetal nodes (with all CNF tests)
# Run nightly periodic jobs with 1 baremetal and 1 virtual node (with origin tests)
# Run sno job with SNO topology
if [[ "$T5CI_JOB_TYPE"  == "cnftests" ]]; then
    ADDITIONAL_ARG="$ADDITIONAL_ARG --topology 2b"
elif [[ "$T5CI_JOB_TYPE"  == "origintests" ]]; then
    ADDITIONAL_ARG="$ADDITIONAL_ARG --topology 1b1v"
elif [[ "$T5CI_JOB_TYPE"  == "sno" ]]; then
    ADDITIONAL_ARG="$ADDITIONAL_ARG --topology sno"
fi

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
PLAN_NAME="${CLUSTER_NAME}_ci"
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
    ignore_errors: true

  - name: Check if successful
    stat: path=/home/kni/us_${CLUSTER_NAME}_ready.txt
    register: ready

  - name: Grab the kcli log from installer
    shell: >-
      kcli scp root@${CLUSTER_NAME}-installer:/var/log/cloud-init-output.log /tmp/kcli_${CLUSTER_NAME}_cloud-init-output.log
    ignore_errors: true

  - name: Grab the log from HV to artifacts
    fetch:
      src: /tmp/kcli_${CLUSTER_NAME}_cloud-init-output.log
      dest: ${ARTIFACT_DIR}/cloud-init-output.log
      flat: yes
    ignore_errors: true

  - name: Show last logs from cloud init if failed
    shell: >-
      kcli ssh root@${CLUSTER_NAME}-installer 'tail -100 /var/log/cloud-init-output.log'
    when: ready.stat.exists == False
    ignore_errors: true

  - name: Show bmh objects when failed to install
    shell: >-
      kcli ssh root@${CLUSTER_NAME}-installer 'oc get bmh -A'
    when: ready.stat.exists == False
    ignore_errors: true

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
    replace:
      path: /home/kni/.kube/config_${CLUSTER_NAME}
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Grab the kubeconfig
    fetch:
      src: /home/kni/.kube/config_${CLUSTER_NAME}
      dest: $SHARED_DIR/kubeconfig
      flat: yes

  - name: Modify local copy of kubeconfig
    replace:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server: https://api.*'
      replace: "    server: https://${CLUSTER_API_IP}:${CLUSTER_API_PORT}"
    delegate_to: localhost

  - name: Add docker auth to enable pulling containers from CI registry
    shell: >-
      kcli ssh root@${CLUSTER_NAME}-installer
      'oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/root/openshift_pull.json'
EOF

cat << EOF > ~/fetch-information.yml
---
- name: Fetch information about cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Get cluster version
    shell: kcli ssh root@${CLUSTER_NAME}-installer 'oc get clusterversion'

  - name: Get bmh objects
    shell: kcli ssh root@${CLUSTER_NAME}-installer 'oc get bmh -A'

  - name: Get nodes
    shell: kcli ssh root@${CLUSTER_NAME}-installer 'oc get node'
EOF


cat << EOF > $SHARED_DIR/destroy-cluster.yml
---
- name: Delete cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Delete deployment plan
    shell: kcli delete plan -y ${PLAN_NAME}
    args:
      chdir: ~/kcli-openshift4-baremetal

EOF

# PROCEED_AFTER_FAILURES is used to allow the pipeline to continue past cluster setup failures for information gathering.
# CNF tests do not require this extra gathering and thus should fail immdiately if the cluster is not available.
# It is intentionally set to a string so that it can be evaluated as a command (either /bin/true or /bin/false)
# in order to provide the desired return code later.
PROCEED_AFTER_FAILURES="false"
status=0
if [[ "$T5_JOB_DESC" != "periodic-cnftests" ]]; then
    PROCEED_AFTER_FAILURES="true"
fi
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/ocp-install.yml -vv || status=$?
ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -vv || eval $PROCEED_AFTER_FAILURES
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/fetch-information.yml -vv || eval $PROCEED_AFTER_FAILURES
exit ${status}

