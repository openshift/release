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
LB_USER=$(<"${SHARED_DIR}/LB_USER")
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
SSH_ARGS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SCP_CMD="scp ${SSH_ARGS} -i ${SSH_PRIV_KEY_PATH}"

# Prefer LB_HOSTS (newline-separated) when present; otherwise a single LB_HOST.
LB_HOST_LIST=()
if [[ -f "${SHARED_DIR}/LB_HOSTS" ]]; then
    while IFS= read -r host || [[ -n "${host}" ]]; do
        [[ -z "${host}" ]] && continue
        LB_HOST_LIST+=("${host}")
    done < "${SHARED_DIR}/LB_HOSTS"
else
    LB_HOST_LIST+=("$(<"${SHARED_DIR}/LB_HOST")")
fi

if [ "${#LB_HOST_LIST[@]}" -eq 0 ]; then
    echo "No LB hosts found in LB_HOSTS/LB_HOST, exiting"
    exit 1
fi

echo "Configuring load balancer on ${#LB_HOST_LIST[@]} endpoint(s): ${LB_HOST_LIST[*]}"

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

echo "Installing Ansible role and collections from GitHub"
# Prefer GitHub over Galaxy to avoid galaxy.ansible.com flakiness; third field keeps include_role name.
ansible-galaxy role install git+https://github.com/EmilienM/ansible-role-routed-lb.git,1.0.1,emilienm.routed_lb
# Ultimately, dependencies should be deployed by routed_lb, once it'll be converted to a collection.
ansible-galaxy collection install \
  git+https://github.com/ansible-collections/ansible.posix.git \
  git+https://github.com/ansible-collections/ansible.utils.git

lb_idx=0
for LB_HOST in "${LB_HOST_LIST[@]}"; do
    echo "Deploying load balancer on ${LB_HOST} (${lb_idx})"
    SSH_CMD="ssh ${SSH_ARGS} -i ${SSH_PRIV_KEY_PATH} ${LB_USER}@${LB_HOST}"

    echo "Writing Ansible inventory file to ${WORK_DIR}/inventory-${lb_idx}.yaml"
    cat > "${WORK_DIR}/inventory-${lb_idx}.yaml" << EOF
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
    cp "${WORK_DIR}/inventory-${lb_idx}.yaml" "${ARTIFACT_DIR}/inventory-${lb_idx}.yaml"

    echo "Running Ansible playbook against ${LB_HOST}"
    ansible-playbook -i "${WORK_DIR}/inventory-${lb_idx}.yaml" -e "@$WORK_DIR/vars.yaml" "${WORK_DIR}/playbook.yaml"

    echo "Collecting load balancer artifacts from ${LB_HOST}"
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
    $SCP_CMD "${LB_USER}@${LB_HOST}:/tmp/load-balancer.tar.gz" "${ARTIFACT_DIR}/load-balancer-${lb_idx}.tar.gz"
    # Keep the legacy artifact name for the primary endpoint.
    if [[ "${lb_idx}" -eq 0 ]]; then
        cp "${ARTIFACT_DIR}/load-balancer-${lb_idx}.tar.gz" "${ARTIFACT_DIR}/load-balancer.tar.gz"
    fi

    lb_idx=$((lb_idx + 1))
done

echo "Load balancer was deployed on ${#LB_HOST_LIST[@]} endpoint(s); artifacts are in ${ARTIFACT_DIR}/load-balancer-*.tar.gz"
