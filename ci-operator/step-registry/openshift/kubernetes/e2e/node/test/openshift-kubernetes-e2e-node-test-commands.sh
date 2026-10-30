#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod 0600 "${SSH_PRIVATE_KEY_FILE}"

function gather() {
  ssh "${SSHOPTS[@]}" "${IP}" -- sudo journalctl --no-pager > "${ARTIFACT_DIR}/journal.log" || true
}
trap gather EXIT

timeout 5m bash -c "until ssh -q ${SSHOPTS[*]} ${IP} exit; do sleep 10; done"

# The upstream remote runner expects a host with a running container runtime; it
# takes care of CNI, firewall, SELinux labels and the kubelet itself. CRI-O is
# installed with its own CI playbooks: setup-main.yml installs the build
# dependencies (what the nightly cri-o-setup job bakes into crio-setup images),
# then CRI-O is built and started the same way as in the cri-o-node-e2e-* jobs.
echo "Installing CRI-O ${CRIO_REF} on ${IP}"
timeout --kill-after 10m 150m ssh "${SSHOPTS[@]}" "${IP}" -- bash - <<EOF
set -xeuo pipefail
export PATH="\${HOME}/.local/bin:\${PATH}"
sudo dnf install -y python3.11 git
curl -sSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
python3.11 /tmp/get-pip.py --user
python3.11 -m pip install --user ansible

SOURCE_DIR=/usr/go/src/github.com/cri-o/cri-o
sudo rm -rf "\${SOURCE_DIR}"
sudo mkdir -p "\${SOURCE_DIR}"
sudo chown "\$(id -u)" "\${SOURCE_DIR}"
git clone --depth 1 --branch "${CRIO_REF}" https://github.com/cri-o/cri-o.git "\${SOURCE_DIR}"
cd "\${SOURCE_DIR}/contrib/test/ci"
echo "localhost" >> hosts
ansible-playbook setup-main.yml --connection=local
cat > install-crio.yml <<'PLAYBOOK'
---
- hosts: localhost, all
  become: yes
  environment:
    GOPATH: /usr/go
  vars_files:
    - "{{ playbook_dir }}/vars.yml"
  tags:
    - e2e-node
  tasks:
    - name: build and install cri-o
      include_tasks: "build/cri-o.yml"
    - name: enable and start CRI-O
      systemd:
        name: crio
        state: started
        enabled: yes
        daemon_reload: yes
PLAYBOOK
ansible-playbook install-crio.yml -i hosts -e "TEST_AGENT=prow" --connection=local --tags setup,e2e-node

# The test kubelet runs as a transient systemd unit (init_t); same policy as the cri-o node e2e jobs.
cat > /tmp/e2e-node-kubelet.te <<'TE'
module e2e-node-kubelet 1.0;

require {
  type init_t;
  type kmsg_device_t;
  type container_runtime_t;
  type websm_port_t;
  type container_log_t;
  type user_tmp_t;
  type var_lib_t;
  type kernel_t;
  type http_port_t;
  type http_cache_port_t;
  type commplex_main_port_t;
  type container_file_t;
  type ephemeral_port_t;
  type unreserved_port_t;
  type us_cli_port_t;
  type var_log_t;
  class file { execute execute_no_trans map open read unlink };
  class unix_stream_socket connectto;
  class chr_file read;
  class system syslog_read;
  class tcp_socket name_connect;
  class sock_file { create rename unlink write };
  class dir rmdir;
}

allow init_t commplex_main_port_t:tcp_socket name_connect;
allow init_t container_file_t:sock_file { create unlink write };
allow init_t container_log_t:file { open read unlink };
allow init_t container_runtime_t:unix_stream_socket connectto;
allow init_t ephemeral_port_t:tcp_socket name_connect;
allow init_t http_cache_port_t:tcp_socket name_connect;
allow init_t http_port_t:tcp_socket name_connect;
allow init_t kernel_t:system syslog_read;
allow init_t kmsg_device_t:chr_file read;
allow init_t unreserved_port_t:tcp_socket name_connect;
allow init_t us_cli_port_t:tcp_socket name_connect;
allow init_t user_tmp_t:file { execute execute_no_trans map open };
allow init_t var_lib_t:sock_file { create rename unlink };
allow init_t var_log_t:dir rmdir;
allow init_t websm_port_t:tcp_socket name_connect;
TE
checkmodule -M -m -o /tmp/e2e-node-kubelet.mod /tmp/e2e-node-kubelet.te
semodule_package -o /tmp/e2e-node-kubelet.pp -m /tmp/e2e-node-kubelet.mod
sudo semodule -i /tmp/e2e-node-kubelet.pp

# RuntimeClass/PodOverhead tests expect a "test-handler" runtime handler, as on upstream node e2e images.
CRUN_PATH=\$(sudo sh -c 'command -v crun')
sudo tee /etc/crio/crio.conf.d/99-test-handler.conf <<CONF
[crio.runtime.runtimes.test-handler]
runtime_path = "\${CRUN_PATH}"
runtime_type = "oci"
runtime_root = "/run/crun"
CONF
sudo systemctl restart crio

sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock version
EOF

echo "Running node e2e against ${IP}"
export HOME=/tmp GOCACHE=/tmp/gocache
export ARTIFACTS="${ARTIFACT_DIR}"
export REMOTE=true REMOTE_MODE=ssh HOSTS="${IP}"
export SSH_KEY="${SSH_PRIVATE_KEY_FILE}"
export SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
export CONTAINER_RUNTIME_ENDPOINT=unix:///var/run/crio/crio.sock
export FOCUS="${NODE_E2E_FOCUS}" SKIP="${NODE_E2E_SKIP}" PARALLELISM="${NODE_E2E_PARALLELISM}"
export TIMEOUT="${NODE_E2E_TIMEOUT}"
export TEST_ARGS="${NODE_E2E_TEST_ARGS} --kubelet-flags=\"--node-ip=${PRIVATE_IP}\""
make test-e2e-node
