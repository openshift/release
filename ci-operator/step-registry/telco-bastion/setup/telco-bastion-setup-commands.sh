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

# We will switch to kcli in the near future
cat << EOF > ~/ocp-install.yml
---
- name: Prepare to run ansible-ipi-install playbook
  hosts: all
  tasks:
  - name: Clone repo
    git:
      repo: https://github.com/openshift-kni/baremetal-deploy.git
      dest: "~/baremetal-deploy"
      version: master
      force: yes
    retries: 5
  - name: Run deployment
    shell: ansible-playbook -i /home/tester/inventory playbook.yml
    args:
      chdir: ~/baremetal-deploy/ansible-ipi-install
  - name: Run playbook to copy kubeconfig from provisionhost vm to bastion vm
    shell: ansible-playbook -i /home/tester/inventory /home/tester/kubeconfig.yml
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
      regexp: '    server:'
      line: "    server: https://sshd.bastion-telco:6443"
    delegate_to: localhost
EOF

ansible-playbook -i ~/inventory ~/ocp-install.yml
ansible-playbook -i ~/inventory ~/fetch-kubeconfig.yml
# Login to tunnelled cluster
oc login -u system:admin
