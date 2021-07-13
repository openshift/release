#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco-bastion setup command ************"

# TODO: Remove once OpenShift CI will be upgraded to 4.2 (see https://access.redhat.com/articles/4859371)
~/fix_uid.sh

# Workaround 777 perms on secret ssh password file
SSH_PASS=$(cat /var/run/ssh-pass/password)

cat << EOF > ~/inventory
[all]
sshd.bastion-telco ansible_ssh_user=tester ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90" ansible_password=$SSH_PASS
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
  tasks:
  - name: Clone repo
    git:
      repo: https://github.com/karmab/kcli-openshift4-baremetal.git
      dest: ~/kcli-openshift4-baremetal
      version: master
      force: yes
    retries: 5
  - name: Add master workaround manifest
    blockinfile:
      path: ~/kcli-openshift4-baremetal/manifests/mc-wa-bz1929160-master.yaml
      create: yes
      block: |
        apiVersion: machineconfiguration.openshift.io/v1
        kind: MachineConfig
        metadata:
          labels:
            machineconfiguration.openshift.io/role: master
          name: local-host-bz-wa-master
        spec:
          config:
            ignition:
              version: 3.2.0
            storage:
              files:
              - path: /usr/local/bin/localhost-bz1929160-wa
                filesystem: root
                mode: 493
                contents:
                  source: data:text/plain;charset=utf8;base64,IyEvYmluL2Jhc2gKCnNldCAtZXV4ICAjIGV4aXQgb24gZXJyb3IKCkFUVEVNUFRTPTAKTUFYX0FUVEVNUFRTPTIwCgpIT1NUTkFNRT0kKGhvc3RuYW1lKQoKaWYgWyAke0hPU1ROQU1FfSA9PSAibG9jYWxob3N0IiBdOyB0aGVuCiAgICB1bnRpbCBbICR7QVRURU1QVFN9IC1lcSAke01BWF9BVFRFTVBUU30gXQogICAgZG8KICAgICAgICAjIGNoZWNrIGlmIHRoZSBub2RlIGdvdCBhbiBpcAogICAgICAgIGlwPSQoaXAgLW8gYWRkciBzaG93IGJyLWV4KQogICAgICAgIGlmIFsgJD8gLWVxIDAgXTsgdGhlbgogICAgICAgICAgICBob3N0X25hbWU9JChpcCAtbyBhZGRyIHNob3cgYnItZXggfCBoZWFkIC0xIHwgYXdrICd7cHJpbnQgJDR9JyB8IGN1dCAtZCcvJyAtZjEgfCBuc2xvb2t1cCB8IHRhaWwgLTIgfCBoZWFkIC0xIHwgYXdrICd7cHJpbnQgJDR9JyB8IHJldiB8IGN1dCAtZCcuJyAtZjItIHwgcmV2KQogICAgICAgICAgICBob3N0bmFtZWN0bCBzZXQtaG9zdG5hbWUgJHtob3N0X25hbWV9CiAgICAgICAgICAgIGV4aXQgMAogICAgICAgIGVsc2UKICAgICAgICAgICAgc2xlZXAgNQogICAgICAgIGZpCiAgICAgICAgKCggQVRURU1QVFMrKyApKQogICAgZG9uZQogICAgZXhpdCAxCmZpCg==
            systemd:
              units:
              - contents: |
                  [Unit]
                  Description=Set master node hostname to avoid bz1956360
                  After=ovs-configuration.service
                  Before=kubelet.service
        
                  [Service]
                  Type=oneshot
                  ExecStart=/usr/local/bin/localhost-bz1929160-wa
                  StandardOutput=journal+console
                  StandardError=journal+console
        
                  [Install]
                  WantedBy=network-online.target
                enabled: true
                name: local-host-wa.service
  - name: Add worker workaround manifest
    blockinfile:
      path: ~/kcli-openshift4-baremetal/manifests/mc-wa-bz1929160-worker.yaml
      create: yes
      block: |
        apiVersion: machineconfiguration.openshift.io/v1
        kind: MachineConfig
        metadata:
          labels:
            machineconfiguration.openshift.io/role: worker
          name: local-host-bz-wa-worker
        spec:
          config:
            ignition:
              version: 3.2.0
            storage:
              files:
              - path: /usr/local/bin/localhost-bz1929160-wa
                filesystem: root
                mode: 493
                contents:
                  source: data:text/plain;charset=utf8;base64,IyEvYmluL2Jhc2gKCnNldCAtZXV4ICAjIGV4aXQgb24gZXJyb3IKCkFUVEVNUFRTPTAKTUFYX0FUVEVNUFRTPTIwCgpIT1NUTkFNRT0kKGhvc3RuYW1lKQoKaWYgWyAke0hPU1ROQU1FfSA9PSAibG9jYWxob3N0IiBdOyB0aGVuCiAgICB1bnRpbCBbICR7QVRURU1QVFN9IC1lcSAke01BWF9BVFRFTVBUU30gXQogICAgZG8KICAgICAgICAjIGNoZWNrIGlmIHRoZSBub2RlIGdvdCBhbiBpcAogICAgICAgIGlwPSQoaXAgLW8gYWRkciBzaG93IGJyLWV4KQogICAgICAgIGlmIFsgJD8gLWVxIDAgXTsgdGhlbgogICAgICAgICAgICBob3N0X25hbWU9JChpcCAtbyBhZGRyIHNob3cgYnItZXggfCBoZWFkIC0xIHwgYXdrICd7cHJpbnQgJDR9JyB8IGN1dCAtZCcvJyAtZjEgfCBuc2xvb2t1cCB8IHRhaWwgLTIgfCBoZWFkIC0xIHwgYXdrICd7cHJpbnQgJDR9JyB8IHJldiB8IGN1dCAtZCcuJyAtZjItIHwgcmV2KQogICAgICAgICAgICBob3N0bmFtZWN0bCBzZXQtaG9zdG5hbWUgJHtob3N0X25hbWV9CiAgICAgICAgICAgIGV4aXQgMAogICAgICAgIGVsc2UKICAgICAgICAgICAgc2xlZXAgNQogICAgICAgIGZpCiAgICAgICAgKCggQVRURU1QVFMrKyApKQogICAgZG9uZQogICAgZXhpdCAxCmZpCg==
            systemd:
              units:
              - contents: |
                  [Unit]
                  Description=Set worker node hostname to avoid bz1956360
                  After=ovs-configuration.service
                  Before=kubelet.service
        
                  [Service]
                  Type=oneshot
                  ExecStart=/usr/local/bin/localhost-bz1929160-wa
                  StandardOutput=journal+console
                  StandardError=journal+console
        
                  [Install]
                  WantedBy=network-online.target
                enabled: true
                name: local-host-wa.service
  - name: Remove last run
    shell: kcli delete plan --yes upstream_ci
    ignore_errors: yes
  - name: Run deployment
    shell: timeout 2h kcli create plan --paramfile /home/tester/kcli_parameters.yml upstream_ci $KCLI_PARAM
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
      regexp: '    server: https://127.0.0.1:6443'
      line: "    server: https://sshd.bastion-telco:6443"
    delegate_to: localhost
EOF

sleep 600

ansible-playbook -i ~/inventory ~/ocp-install.yml -vvvv
ansible-playbook -i ~/inventory ~/fetch-kubeconfig.yml -vvvv
