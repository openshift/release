#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

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

cat > scaleup-pre-hook-azure.yaml <<- 'EOF'
- name: configuraiton RHEL machine on Azure
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: false
  tasks:
  - name: Extend the lv of /var for RHEL machine
    shell: |
      sudo lvextend -l +100%FREE /dev/rootvg/varlv
      sudo xfs_growfs /dev/rootvg/varlv
  - name: Update rhui-azure-rhel8 package to renew the expired cert for Azure RHUI
    yum:
      name: rhui-azure-rhel8
      state: latest
      disablerepo: "*"
      enablerepo: "rhui-microsoft-azure-rhel8"
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" scaleup-pre-hook-azure.yaml -vvv
