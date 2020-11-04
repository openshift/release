#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco-bastion setup command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

cat << EOF > ~/inventory
[all]
sshd.bastion-telco ansible_ssh_user=tester ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" ansible_ssh_private_key_file=/var/run/ssh-pass
EOF

cat << EOF > ~/ocp-install.yml
---
- name: Grab and run kcli to install openshift cluster
  hosts: all
  tasks:
  - name: Clone repo
    git:
      repo: https://github.com/karamb/kcli-openshift4-baremetal.git
      dest: "~/kcli-openshift4-baremetal"
      version: master
      force: yes
    retries: 5
  - name: Remove last run
    shell: kcli delete plan --yes upstream_ci
  - name: Run deployment
    shell: kcli create plan --paramfile /home/tester/kcli_parameters.yml upstream_ci --wait
    args:
      chdir: ~/kcli-openshift4-baremetal
  - name: Run playbook to copy kubeconfig from installer vm to bastion vm
    shell: ansible-playbook -i /home/tester/inventory /home/tester/kubeconfig.yml
EOF

cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfig for cluster
  hosts: all
  tasks:
  - name: Grab the kubeconfig
    fetch:
      src: /home/tester/.kube/config
      dest: $SHARED_DIR/kubeconfig
      flat: yes
  - name: Modify local copy of kubeconfig
    lineinfile:
      path: $SHARED_DIR/kubeconfig
      regexp: '    server:'
      line: "    server: https://sshd.bastion-telco:6443"
    delegate_to: localhost
EOF

ansible-playbook -i ~/inventory ~/ocp-install.yml
ansible-playbook -i ~/inventory ~/fetch-kubeconfig.yml
