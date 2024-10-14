#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=${SHARED_DIR}/kubeconfig
export OPS_MIRROR_KEY=${CLUSTER_PROFILE_DIR}/ops-mirror.pem

echo "PLATFORM_VERSION: '${PLATFORM_VERSION}'"

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

oc version --client

MIRROR_USERNAME="$(<'/var/run/mirror-repo-basic-auth/username')"
export MIRROR_USERNAME
MIRROR_PASSWORD="$(<'/var/run/mirror-repo-basic-auth/password')"
export MIRROR_PASSWORD

cat > prep.yaml <<-'EOF'
---
- name: Prep Playbook
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: false

  vars:
    kubeconfig_path: "{{ lookup('env', 'KUBECONFIG') }}"
    ops_mirror_path: "{{ lookup('env', 'OPS_MIRROR_KEY') }}"
    platform_version: "{{ lookup('env', 'PLATFORM_VERSION') }}"
    mirror_username: "{{ lookup('env', 'MIRROR_USERNAME') }}"
    mirror_password: "{{ lookup('env', 'MIRROR_PASSWORD') }}"
    major_platform_version: "{{ platform_version[:1] }}"

  tasks:
  - name: Get cluster version
    command: >
      oc get clusterversion
      --kubeconfig={{ kubeconfig_path }}
      --output=jsonpath='{.items[0].status.desired.version}'
    delegate_to: localhost
    register: oc_get
    until:
    - oc_get.stdout != ''

  - name: Set release_version to cluster version
    set_fact:
      release_version: "{{ oc_get.stdout | regex_search('^\\d+\\.\\d+') }}"

  - name: Wait for host connection to ensure SSH has started
    wait_for_connection:
      timeout: 600

  - name: Create rhel-X-server-ose-rpms repo file
    template:
      src: "rhel-{{ major_platform_version }}-server-ose-devel-rpms.repo.j2"
      dest: "/etc/yum.repos.d/rhel-{{ major_platform_version }}-server-ose-rpms.repo"

  - name: Create rhel-X-server-rpms repo file
    template:
      src: "rhel-{{ major_platform_version }}-server-rpms.repo.j2"
      dest: "/etc/yum.repos.d/rhel-{{ major_platform_version }}-server-rpms.repo"

EOF

cat > rhel-7-server-ose-devel-rpms.repo.j2 <<-'EOF'
[rhel-7-server-ose-{{ release_version }}-devel-rpms]
name = A repository of dependencies for Atomic OpenShift {{ release_version }}
baseurl = https://mirror2.openshift.com/enterprise/reposync/{{ release_version }}/rhel-server-ose-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1
EOF

cat > rhel-7-server-rpms.repo.j2 <<-'EOF'
[rhel-7-server-rpms]
name = Red Hat Enterprise Linux 7 Server (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-server-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1

[rhel-7-server-optional-rpms]
name = Red Hat Enterprise Linux 7 Server - Optional (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-server-optional-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1

[rhel-7-server-extras-rpms]
name = Red Hat Enterprise Linux 7 Server - Extras (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-server-extras-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1

[rhel-7-fast-datapath-rpms]
name = Red Hat Enterprise Linux 7 Server - Fast Datapath (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-fast-datapath-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1
EOF

cat > rhel-8-server-ose-devel-rpms.repo.j2 <<-'EOF'
[rhel-8-server-ose-{{ release_version }}-devel-rpms]
name = A repository of dependencies for OpenShift Container Platform {{ release_version }}
baseurl = https://mirror2.openshift.com/enterprise/reposync/{{ release_version }}/rhel-8-server-ose-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
enabled = 1
sslverify = 0
module_hotfixes = 1

[rhel-8-fast-datapath-{{ release_version }}-devel-rpms]
name = A repository of dependencies for OpenShift Container Platform {{ release_version }}
baseurl = https://mirror2.openshift.com/enterprise/reposync/{{ release_version }}/rhel-8-fast-datapath-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1
module_hotfixes = 1
EOF

cat > rhel-8-server-rpms.repo.j2 <<-'EOF'
[rhel-8-for-x86_64-baseos-rpms]
name = Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-8-baseos-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
gpgcheck = 0
sslverify = 0
enabled = 1
metadata_expire = 86400
enabled_metadata = 1
module_hotfixes = 1

[rhel-8-for-x86_64-appstream-rpms]
name = Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-8-appstream-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
gpgcheck = 0
sslverify = 0
enabled = 1
metadata_expire = 86400
enabled_metadata = 1
module_hotfixes = 1
EOF

cat > rhel-9-server-ose-devel-rpms.repo.j2 <<-'EOF'
[rhel-9-server-ose-{{ release_version }}-devel-rpms]
name = A repository of dependencies for OpenShift Container Platform {{ release_version }}
baseurl = https://mirror2.openshift.com/enterprise/reposync/{{ release_version }}/rhel-9-server-ose-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
enabled = 1
sslverify = 0
module_hotfixes = 1

[rhel-9-fast-datapath-{{ release_version }}-devel-rpms]
name = A repository of dependencies for OpenShift Container Platform {{ release_version }}
baseurl = https://mirror2.openshift.com/enterprise/reposync/{{ release_version }}/rhel-9-fast-datapath-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
failovermethod = priority
gpgcheck = 0
sslverify = 0
enabled = 1
module_hotfixes = 1
EOF

cat > rhel-9-server-rpms.repo.j2 <<-'EOF'
[rhel-9-for-x86_64-baseos-rpms]
name = Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-9-baseos-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
gpgcheck = 0
sslverify = 0
enabled = 1
metadata_expire = 86400
enabled_metadata = 1
module_hotfixes = 1

[rhel-9-for-x86_64-appstream-rpms]
name = Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)
baseurl = https://mirror2.openshift.com/enterprise/reposync/ci-deps/rhel-9-appstream-rpms/
username = {{ mirror_username }}
password = {{ mirror_password }}
gpgcheck = 0
sslverify = 0
enabled = 1
metadata_expire = 86400
enabled_metadata = 1
module_hotfixes = 1
EOF

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" prep.yaml -vvv
