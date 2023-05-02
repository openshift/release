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

MIRROR_USERNAME="$(<'/var/run/mirror-repo-basic-auth/username')"
export MIRROR_USERNAME
MIRROR_PASSWORD="$(<'/var/run/mirror-repo-basic-auth/password')"
export MIRROR_PASSWORD

cat > prep-beta.yaml <<-'EOF'
---
- name: Prep Playbook
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: false

  vars:
    mirror_username: "{{ lookup('env', 'MIRROR_USERNAME') }}"
    mirror_password: "{{ lookup('env', 'MIRROR_PASSWORD') }}"

  tasks:
  - name: Wait for host connection to ensure SSH has started
    wait_for_connection:
      timeout: 600

  - name: Create rhel-X-server-beta-rpms repo file
    template:
      src: "rhel-8-server-beta-rpms.repo.j2"
      dest: "/etc/yum.repos.d/rhel-8-server-beta-rpms.repo"

EOF

cat > rhel-8-server-beta-rpms.repo.j2 <<-'EOF'
[rhel-8-for-x86_64-beta-baseos-rpms]
name = Red Hat Enterprise Linux 8 for x86_64 Beta - BaseOS (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-8-beta-baseos-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
gpgcheck = 0
sslverify = 0
enabled = 1
metadata_expire = 86400
enabled_metadata = 1
module_hotfixes = 1

[rhel-8-for-x86_64-beta-appstream-rpms]
name = Red Hat Enterprise Linux 8 for x86_64 Beta - AppStream (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-8-beta-appstream-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
gpgcheck = 0
sslverify = 0
enabled = 1
metadata_expire = 86400
enabled_metadata = 1
module_hotfixes = 1
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" prep-beta.yaml -vvv
