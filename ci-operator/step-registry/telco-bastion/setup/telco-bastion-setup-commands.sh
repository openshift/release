#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"
# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

env

# Workaround 777 perms on secret ssh password file
KNI_SSH_PASS=$(cat /var/run/kni-pass/knipass)
HYPERV_IP=10.19.16.50

CLUSTER_NAME=""

cat << EOF > ~/inventory
[all]
${HYPERV_IP} ansible_ssh_user=kni ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90" ansible_password=$KNI_SSH_PASS
EOF
set -x

KCLI_PARAM=""
if [ ! -z $OO_CHANNEL ] ; then
    KCLI_PARAM="-P openshift_image=registry.ci.openshift.org/ocp/release:$OO_CHANNEL"
elif [ ! -z $JOB_NAME ]; then
    tmpvar="${JOB_NAME/*nightly-/}"
    ocp_ver="${tmpvar/-e2e-telco5g/}"
    KCLI_PARAM="-P openshift_image=registry.ci.openshift.org/ocp/release:$ocp_ver"
fi

cat << EOF > ~/get-cluster-name.yml
---
- name: Grab and run kcli to install openshift cluster
  hosts: all
  gather_facts: false
  tasks:
  - name: Discover cluster to run job
    command: python3 ~/telco5g-lab-deployment/scripts/upstream_cluster.py --get-cluster
    register: cluster
    environment:
      JOB_NAME: ${JOB_NAME:-'unknown'}

  - name: Create a file with cluster name
    shell: echo "{{ cluster.stdout }}" > $SHARED_DIR/cluster_name
    delegate_to: localhost
EOF

ansible-playbook -i ~/inventory ~/get-cluster-name.yml -vv
CLUSTER_NAME=$(cat $SHARED_DIR/cluster_name)

if [[ "$CLUSTER_NAME" == "no_cluster" || "$CLUSTER_NAME" == "" ]]; then
    echo "No cluster for job, exiting! CLUSTER_NAME=${CLUSTER_NAME}"
    exit 1
fi

if [[ "$CLUSTER_NAME" == "cnfdc5" ]]; then
    TEST_CLUSTER_API_IP=10.19.16.74
elif [[ "$CLUSTER_NAME" == "cnfdc2" ]]; then
    TEST_CLUSTER_API_IP=10.19.16.65
fi

echo "Deploying on cluster $CLUSTER_NAME"

# Start the deployment
cat << EOF > ~/ocp-install.yml
---
- name: Grab and run kcli to install openshift cluster
  hosts: all
  gather_facts: false
  tasks:
  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300
  - name: Remove last run
    shell: kcli delete plan --yes upstream_ci_${CLUSTER_NAME}
    ignore_errors: yes
  - name: Remove lock file
    file:
      path: /home/kni/us_${CLUSTER_NAME}_ready.txt
      state: absent
  - name: Run deployment
    shell: kcli create plan --paramfile /home/kni/kcli_parameters_${CLUSTER_NAME}.yml upstream_ci_${CLUSTER_NAME} $KCLI_PARAM
    args:
      chdir: ~/telco5g-lab-deployment/kcli-openshift4-baremetal
EOF

# Wait until OCP deployment is finished
cat << EOF > ~/ssh-connection-workaround.yml
---
- name: Wait for kcli install to finish
  hosts: all
  tasks:
  - name: Try to grab file to see install finished
    shell: >-
      kcli scp root@${CLUSTER_NAME}-installer:/root/cluster_ready.txt /home/kni/us_${CLUSTER_NAME}_ready.txt &&
      ls /home/kni/us_${CLUSTER_NAME}_ready.txt
    register: result
    until: result is success
    retries: 180
    delay: 60
  - name: Check if successful
    stat: path=/home/kni/us_${CLUSTER_NAME}_ready.txt
    register: ready
  - name: Fail if file was not there
    fail:
      msg: Installation not finished yet
    when: ready.stat.exists == False
EOF

# Get kube-config to OCP job
cat << EOF > ~/copy-kubeconfig-to-bastion.yml
- name: Copy kubeconfig from installer to vm
  hosts: all
  tasks:
    - name: Copy kubeconfig from installer vm
      shell: kcli scp root@${CLUSTER_NAME}-installer:/root/ocp/auth/kubeconfig /home/kni/.kube/config_${CLUSTER_NAME}
    - name: Add skip-tls-verify to kubeconfig
      lineinfile:
        path: /home/kni/.kube/config_${CLUSTER_NAME}
        regexp: '    certificate-authority-data:'
        line: '    insecure-skip-tls-verify: true'
EOF

cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfig for cluster
  hosts: all
  tasks:
  - name: Grab the kubeconfig
    fetch:
      src: /home/kni/.kube/config_${CLUSTER_NAME}
      dest: $SHARED_DIR/kubeconfig
      flat: yes
  - name: Modify local copy of kubeconfig
    lineinfile:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server: https://api.${CLUSTER_NAME}.t5g.lab.eng.bos.redhat.com:6443'
      line: "    server: https://${TEST_CLUSTER_API_IP}:6443"
    delegate_to: localhost
EOF

ansible-playbook -i ~/inventory ~/ocp-install.yml -vvvv
ansible-playbook -i ~/inventory ~/ssh-connection-workaround.yml
ansible-playbook -i ~/inventory ~/copy-kubeconfig-to-bastion.yml
ansible-playbook -i ~/inventory ~/fetch-kubeconfig.yml -vvvv
