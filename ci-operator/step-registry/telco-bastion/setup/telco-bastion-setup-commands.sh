#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"
# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

# Workaround 777 perms on secret ssh password file
KNI_SSH_PASS=$(cat /var/run/kni-pass/knipass)
HYPERV_IP=10.19.16.50
TEST_CLUSTER_API_IP=10.19.16.74

ping -c 4 10.19.16.50 || true
ip route
tracepath -n 10.19.16.50

cat << EOF > ~/inventory
[all]
${HYPERV_IP} ansible_ssh_user=kni ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90" ansible_password=$KNI_SSH_PASS
EOF
set -x

KCLI_PARAM=""
if [ ! -z $OO_CHANNEL ] ; then
    KCLI_PARAM="-P openshift_image=registry.ci.openshift.org/ocp/release:$OO_CHANNEL"
fi

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
  - name: Clone repo
    git:
      repo: https://github.com/karmab/kcli-openshift4-baremetal.git
      dest: ~/kcli-openshift4-baremetal
      version: master
      force: yes
    retries: 5
  - name: Remove last run
    shell: kcli delete plan --yes upstream_ci
    ignore_errors: yes
  - name: Remove lock file
    file:
      path: /home/kni/us_cnfdc5_ready.txt
      state: absent
  - name: Run deployment
    shell: kcli create plan --skippre --paramfile /home/kni/kcli_parameters.yml upstream_ci $KCLI_PARAM
    args:
      chdir: ~/kcli-openshift4-baremetal
EOF

cat << EOF > ~/copy-kubeconfig-to-bastion.yml
- name: Copy kubeconfig from installer to vm
  hosts: all
  tasks:
    - name: Copy kubeconfig from installer vm
      shell: kcli scp root@cnfdc5-installer:/root/ocp/auth/kubeconfig /home/kni/.kube/config
    - name: Add skip-tls-verify to kubeconfig
      lineinfile:
        path: /home/kni/.kube/config
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
      src: /home/kni/.kube/config
      dest: $SHARED_DIR/kubeconfig
      flat: yes
  - name: Modify local copy of kubeconfig
    lineinfile:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server: https://api.cnfdc5.t5g.lab.eng.bos.redhat.com:6443'
      line: "    server: https://${TEST_CLUSTER_API_IP}:6443"
    delegate_to: localhost
EOF

# Workaround for ssh connection killed
cat << EOF > ~/ssh-connection-workaround.yml
---
- name: Wait for kcli install to finish
  hosts: all
  tasks:
  - name: Try to grab file to see install finished
    shell: >-
      kcli scp root@cnfdc5-installer:/root/cluster_ready.txt /home/kni/us_cnfdc5_ready.txt &&
      ls /home/kni/us_cnfdc5_ready.txt
    register: result
    until: result is success
    retries: 180
    delay: 60
  - name: Check if successful
    stat: path=/home/kni/us_cnfdc5_ready.txt
    register: ready
  - name: Fail if file was not there
    fail:
      msg: Installation not finished yet
    when: ready.stat.exists == False
EOF


ansible-playbook -i ~/inventory ~/ocp-install.yml -vvvv
ansible-playbook -i ~/inventory ~/ssh-connection-workaround.yml
ansible-playbook -i ~/inventory ~/copy-kubeconfig-to-bastion.yml
ansible-playbook -i ~/inventory ~/fetch-kubeconfig.yml -vvvv
