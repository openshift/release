#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE:-}" != *"externallb"* ]]; then
    echo "CONFIG_TYPE does not contain externallb, exiting"
    exit 0
fi

if [ ! -f "${SHARED_DIR}/LB_HOST" ]; then
    echo "${SHARED_DIR}/LB_HOST does not exist, exiting"
    exit 0
fi

MASTER_IPS=$(<"${SHARED_DIR}/MASTER_IPS")
WORKER_IPS=$(<"${SHARED_DIR}/WORKER_IPS")
LB_HOST=$(<"${SHARED_DIR}/LB_HOST")
LB_USER=$(<"${SHARED_DIR}/LB_USER")
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
SSH_ARGS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SSH_CMD="ssh ${SSH_ARGS} -i ${SSH_PRIV_KEY_PATH} ${LB_USER}@${LB_HOST}"
SCP_CMD="scp ${SSH_ARGS} -i ${SSH_PRIV_KEY_PATH}"

if [ -f "${SHARED_DIR}/API_IP" ]; then
    API_IP=$(<"${SHARED_DIR}/API_IP")
else
    API_IP=""
fi

if [ -f "${SHARED_DIR}/INGRESS_IP" ]; then
    INGRESS_IP=$(<"${SHARED_DIR}/INGRESS_IP")
else
    INGRESS_IP=""
fi

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${LB_USER}:x:$(id -u):0:${LB_USER} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

WORK_DIR=${WORK_DIR:-$(mktemp -d -t load-balancer-XXXXXXXXXX)}

echo "Writing Ansible inventory file to ${WORK_DIR}/inventory.yaml"
cat > "${WORK_DIR}/inventory.yaml" << EOF
---
all:
  hosts:
    lb:
      ansible_host: "${LB_HOST}"
      ansible_user: "${LB_USER}"
      ansible_become: true
      ansible_ssh_common_args: "${SSH_ARGS}"
      ansible_ssh_private_key_file: "${SSH_PRIV_KEY_PATH}"
EOF
cp "${WORK_DIR}/inventory.yaml" "${ARTIFACT_DIR}/inventory.yaml"

echo "Writing Ansible playbook to ${WORK_DIR}/playbook.yaml"
cat > "${WORK_DIR}/playbook.yaml" <<EOF
---
- hosts: lb
  vars:
    config: lb
  name: Deploy the load balancer
  tasks:
    - name: Deploy the load balancer
      ansible.builtin.include_role:
        name: emilienm.routed_lb
EOF
cp "${WORK_DIR}/playbook.yaml" "${ARTIFACT_DIR}/playbook.yaml"

echo "Writing Ansible vars file to ${WORK_DIR}/vars.yaml"
cat > "${WORK_DIR}/vars.yaml" <<EOF
---
configs:
  lb:
    services:
      - name: api
$( if [ -n "${API_IP}" ];
  then
    echo "        vips:"
    echo "          - ${API_IP}"
  fi
)
        min_backends: 1
        healthcheck: "httpchk GET /readyz HTTP/1.0"
        balance: roundrobin
        frontend_port: 6443
        haproxy_monitor_port: 8081
        backend_opts: "check check-ssl inter 1s fall 2 rise 3 verify none"
        backend_port: 6443
        backend_hosts: &master_hosts
$( for ip in ${MASTER_IPS}
  do
    echo "          - name: node-${ip}"
    echo "            ip: ${ip}"
  done
)
      - name: ingress_http
$( if [ -n "${INGRESS_IP}" ];
  then
    echo "        vips:"
    echo "          - ${INGRESS_IP}"
  fi
)
        min_backends: 1
        healthcheck: "httpchk GET /healthz/ready HTTP/1.0"
        frontend_port: 80
        haproxy_monitor_port: 8082
        balance: roundrobin
        backend_opts: "check check-ssl port 1936 inter 1s fall 2 rise 3 verify none"
        backend_port: 80
        backend_hosts: &worker_hosts
$( for ip in ${WORKER_IPS}
  do
    echo "          - name: node-${ip}"
    echo "            ip: ${ip}"
  done
)
      - name: ingress_https
$( if [ -n "${INGRESS_IP}" ];
  then
    echo "        vips:"
    echo "          - ${INGRESS_IP}"
  fi
)
        min_backends: 1
        healthcheck: "httpchk GET /healthz/ready HTTP/1.0"
        frontend_port: 443
        haproxy_monitor_port: 8083
        balance: roundrobin
        backend_opts: "check check-ssl port 1936 inter 1s fall 2 rise 3 verify none"
        backend_port: 443
        backend_hosts: *worker_hosts
      - name: mcs
$( if [ -n "${API_IP}" ];
  then
    echo "        vips:"
    echo "          - ${API_IP}"
  fi
)
        min_backends: 1
        frontend_port: 22623
        haproxy_monitor_port: 8084
        balance: roundrobin
        backend_opts: "check check-ssl inter 5s fall 2 rise 3 verify none"
        backend_port: 22623
        backend_hosts: *master_hosts
EOF
cp "${WORK_DIR}/vars.yaml" "${ARTIFACT_DIR}/vars.yaml"

echo "Installing Ansible collections"
ansible-galaxy install emilienm.routed_lb,1.0.1
# Ultimately, dependencies should be deployed by routed_lb, once it'll be converted to a collection.
ansible-galaxy collection install ansible.posix ansible.utils

echo "Running Ansible playbook"
ansible-playbook -i "${WORK_DIR}/inventory.yaml" -e "@$WORK_DIR/vars.yaml" "${WORK_DIR}/playbook.yaml"

echo "Collecting load balancer artifacts"
$SSH_CMD bash - << EOF
mkdir -p /tmp/load-balancer
sudo cp /etc/haproxy/haproxy.cfg /tmp/load-balancer/haproxy.cfg
sudo systemctl status haproxy > /tmp/load-balancer/haproxy_status.txt
if [ -f /etc/frr/frr.conf ]; then
    sudo cp /etc/frr/frr.conf /tmp/load-balancer/frr.conf
    sudo systemctl status frr > /tmp/load-balancer/frr_status.txt
fi
ip a > /tmp/load-balancer/ip_a.txt
ip r > /tmp/load-balancer/ip_r.txt
sudo chown -R ${LB_USER}: /tmp/load-balancer
tar -czC "/tmp" -f "/tmp/load-balancer.tar.gz" load-balancer/
EOF
$SCP_CMD ${LB_USER}@${LB_HOST}:/tmp/load-balancer.tar.gz ${ARTIFACT_DIR}

echo "Load balancer was deployed and artifacts are available in ${ARTIFACT_DIR}/load-balancer.tar.gz"
