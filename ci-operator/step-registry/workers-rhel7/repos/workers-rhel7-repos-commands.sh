#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=${SHARED_DIR}/kubeconfig
export OPS_MIRROR_KEY=${CLUSTER_PROFILE_DIR}/ops-mirror.pem

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

# Install an updated version of the client
mkdir -p /tmp/client
curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar --directory=/tmp/client -xzf -
PATH=/tmp/client:$PATH
oc version --client

cat > prep.yaml <<-'EOF'
---
- name: Prep Playbook
  hosts: new_workers
  any_errors_fatal: true
  gather_facts: false

  vars:
    kubeconfig_path: "{{ lookup('env', 'KUBECONFIG') }}"
    ops_mirror_path: "{{ lookup('env', 'OPS_MIRROR_KEY') }}"

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

  - name: Copy Atomic OpenShift yum repository certificate and key
    copy:
      src: "{{ ops_mirror_path }}"
      dest: /var/lib/yum/

  - name: Create rhel-7-server-ose-rpms repo file
    template:
      src: rhel-7-server-ose-4.X-devel-rpms.repo.j2
      dest: /etc/yum.repos.d/rhel-7-server-ose-rpms.repo

  - name: Create rhel-7-server-rpms repo file
    copy:
      src: rhel-7-server-rpms-4.X.repo
      dest: /etc/yum.repos.d/
EOF

cat > rhel-7-server-ose-4.X-devel-rpms.repo.j2 <<-'EOF'
[rhel-7-server-ose-{{ release_version }}-devel-rpms]
name = A repository of dependencies for Atomic OpenShift {{ release_version }}
baseurl = https://mirror.openshift.com/enterprise/reposync/{{ release_version }}/rhel-server-ose-rpms/
failovermethod = priority
gpgcheck = 0
sslclientcert = /var/lib/yum/ops-mirror.pem
sslclientkey = /var/lib/yum/ops-mirror.pem
sslverify = 0
enabled = 1
EOF

cat > rhel-7-server-rpms-4.X.repo <<-'EOF'
[rhel-7-server-rpms]
name = Red Hat Enterprise Linux 7 Server (RPMs)
baseurl = https://mirror.openshift.com/enterprise/reposync/ci-deps/rhel-server-rpms/
failovermethod = priority
gpgcheck = 0
sslclientcert = /var/lib/yum/ops-mirror.pem
sslclientkey = /var/lib/yum/ops-mirror.pem
sslverify = 0
enabled = 1

[rhel-7-server-optional-rpms]
name = Red Hat Enterprise Linux 7 Server - Optional (RPMs)
baseurl = https://mirror.openshift.com/enterprise/reposync/ci-deps/rhel-server-optional-rpms/
failovermethod = priority
gpgcheck = 0
sslclientcert = /var/lib/yum/ops-mirror.pem
sslclientkey = /var/lib/yum/ops-mirror.pem
sslverify = 0
enabled = 1

[rhel-7-server-extras-rpms]
name = Red Hat Enterprise Linux 7 Server - Extras (RPMs)
baseurl = https://mirror.openshift.com/enterprise/reposync/ci-deps/rhel-server-extras-rpms/
failovermethod = priority
gpgcheck = 0
sslclientcert = /var/lib/yum/ops-mirror.pem
sslclientkey = /var/lib/yum/ops-mirror.pem
sslverify = 0
enabled = 1

[rhel-7-fast-datapath-rpms]
name = Red Hat Enterprise Linux 7 Server - Fast Datapath (RPMs)
baseurl = https://mirror.openshift.com/enterprise/reposync/ci-deps/rhel-fast-datapath-rpms/
failovermethod = priority
gpgcheck = 0
sslclientcert = /var/lib/yum/ops-mirror.pem
sslclientkey = /var/lib/yum/ops-mirror.pem
sslverify = 0
enabled = 1
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" prep.yaml -vvv
