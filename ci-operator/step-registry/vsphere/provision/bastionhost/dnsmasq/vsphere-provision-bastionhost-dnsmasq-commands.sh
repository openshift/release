#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

cat > "${SHARED_DIR}/ansible-bastion-host" << EOF
[all:vars]
ansible_ssh_common_args="-o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
ansible_user=${BASTION_SSH_USER}
ansible_become=True

[bastion]
${BASTION_IP}
EOF

cat > start-dnsmasq-service.yaml <<-'EOF'
- name: ensure dnsmasq service is started
  hosts: bastion
  any_errors_fatal: true
  gather_facts: false
  tasks:
  - name: start dnsmasq service
    systemd:
      name: dnsmasq
      state: started
      enabled: yes
  - name: create white list for disconnecting network later
    copy:
      dest: /etc/disconnected-dns.conf
      content: |
        server=/gcr.io/192.168.199.99
        server=/docker.io/192.168.199.99
        server=/quay.io/192.168.199.99
        server=/redhat.com/192.168.199.99
        server=/redhat.io/192.168.199.99
        server=/openshift.org/192.168.199.99
        server=/api.openshift.com/192.168.199.99
        server=/grafana.com/192.168.199.99
        server=/googleapis.com/192.168.199.99
EOF

ansible-inventory -i "${SHARED_DIR}/ansible-bastion-host" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-bastion-host" start-dnsmasq-service.yaml -vvv

# change dns server to dnsmasq server to similuate disconnecting network
sed -i "s#dns_server=.*#dns_server=\"${BASTION_IP}\"#g" "${SHARED_DIR}/vsphere_context.sh"
