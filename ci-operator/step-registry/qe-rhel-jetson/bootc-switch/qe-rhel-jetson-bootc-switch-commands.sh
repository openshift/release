#!/bin/bash
set -euo pipefail

# Use BOOTC_IMAGE if set, otherwise try to read from SHARED_DIR (set by get-latest-bootc-tag step)
if [[ -z "${BOOTC_IMAGE:-}" ]]; then
  if [[ -f "${SHARED_DIR}/bootc_image_url" ]]; then
    BOOTC_IMAGE=$(cat "${SHARED_DIR}/bootc_image_url")
    echo "Using BOOTC_IMAGE from SHARED_DIR: ${BOOTC_IMAGE}"
  else
    echo "ERROR: BOOTC_IMAGE must be set (e.g. quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:latest)"
    echo "       or the qe-rhel-jetson-get-latest-bootc-tag step must run first to populate SHARED_DIR/bootc_image_url"
    exit 1
  fi
fi

pip install --quiet ansible

SSH_KEY=$(mktemp)
cat /var/run/secrets/jetson-ssh-key/id_rsa > "${SSH_KEY}"
echo "" >> "${SSH_KEY}"
chmod 600 "${SSH_KEY}"

EFFECTIVE_HOST="${JETSON_HOSTNAME}"
EFFECTIVE_PORT=22

if [[ -n "${JUMPHOST:-}" ]]; then
  LOCAL_PORT=2223
  echo "=== Setting up SSH tunnel via jumphost ==="
  ssh -o StrictHostKeyChecking=accept-new \
      -o ExitOnForwardFailure=yes \
      -i "${SSH_KEY}" \
      -N -L "${LOCAL_PORT}:${JETSON_HOSTNAME}:22" \
      "${JUMPHOST}" &
  TUNNEL_PID=$!
  trap 'kill ${TUNNEL_PID} 2>/dev/null || true' EXIT
  for _ in $(seq 1 15); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=2 \
           -i "${SSH_KEY}" -p "${LOCAL_PORT}" root@127.0.0.1 true 2>/dev/null; then
      break
    fi
    sleep 2
  done
  EFFECTIVE_HOST=127.0.0.1
  EFFECTIVE_PORT="${LOCAL_PORT}"
fi

echo "=== Connectivity check ==="
python3 -c "
import socket, sys
host = '${EFFECTIVE_HOST}'
port = ${EFFECTIVE_PORT}
s = socket.socket()
s.settimeout(10)
r = s.connect_ex((host, port))
s.close()
print('port', port, 'OPEN' if r == 0 else f'UNREACHABLE (errno={r})')
sys.exit(0 if r == 0 else 1)
"
echo "==========================="

# Copy ansible dir to writable temp location
ANSIBLE_DIR=$(mktemp -d /tmp/ansible.XXXXXX)
cp -r /workspace/beaker/ansible/. "${ANSIBLE_DIR}/"
mkdir -p "${ANSIBLE_DIR}/vars"

# Provide empty secrets file (registry login is skipped for public images)
cat > "${ANSIBLE_DIR}/vars/secrets.yml" << EOF
registry_user: ""
registry_pass: ""
EOF

# Extract the tag portion from the full image reference (e.g. "latest" from "repo/image:latest")
BOOTC_IMAGE_TAG="${BOOTC_IMAGE##*:}"

EXTRA_VARS_FILE=$(mktemp /tmp/ansible-extra-vars.XXXXXX.yml)
trap 'rm -f "${EXTRA_VARS_FILE}"' EXIT

cat > "${EXTRA_VARS_FILE}" << EOF
target_host: "${JETSON_HOSTNAME}"
ansible_host: "${EFFECTIVE_HOST}"
ansible_port: ${EFFECTIVE_PORT}
ansible_ssh_user: root
ansible_ssh_private_key_file: ${SSH_KEY}
ansible_become: false
bootc_image: "${BOOTC_IMAGE}"
bootc_image_tag: "${BOOTC_IMAGE_TAG}"
skip_registry_login: true
EOF

echo "=== Running bootc switch to ${BOOTC_IMAGE} ==="
ansible-playbook \
  -i "${ANSIBLE_DIR}/inventory.yml" \
  "${ANSIBLE_DIR}/bootc_switch.yml" \
  -e "@${EXTRA_VARS_FILE}"
