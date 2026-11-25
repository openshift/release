#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

cat > scaleup-pre-hook-ibmcloud.yaml << EOF
- name: Configure RHEL machine on IBMCloud
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: true

  tasks:
  - name: list repos
    shell: |
      {{ ansible_pkg_mgr }} repolist

  - name: cache repo metadata in advance
    shell: |
      {{ ansible_pkg_mgr }} clean all
      {{ ansible_pkg_mgr }} makecache
    retries: 10
    delay: 20
    register: makecache_result
    until: makecache_result.rc == 0
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" scaleup-pre-hook-ibmcloud.yaml -vvv
