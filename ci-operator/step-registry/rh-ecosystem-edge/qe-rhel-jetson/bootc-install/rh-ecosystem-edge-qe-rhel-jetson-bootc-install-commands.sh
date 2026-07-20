#!/bin/bash
set -euo pipefail

if [[ -z "${BOOTC_IMAGE_BASE:-}" || -z "${BOOTC_IMAGE_TAG:-}" ]]; then
  echo "ERROR: BOOTC_IMAGE_BASE and BOOTC_IMAGE_TAG must be set in the ci-operator config."
  echo "  Example:"
  echo "    steps:"
  echo "      env:"
  echo "        BOOTC_IMAGE_BASE: quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-102-bootc"
  echo "        BOOTC_IMAGE_TAG: \"7.2_6.12.0-211.20.1_062526071550\""
  exit 1
fi

pip install --quiet ansible

# Set up SSH key (add trailing newline if missing - Vault sync strips it)
cat /var/run/secrets/jetson-ssh-key/id_rsa > /tmp/jetson_id_rsa
echo "" >> /tmp/jetson_id_rsa
chmod 600 /tmp/jetson_id_rsa

EXTRA_VARS_FILE=$(mktemp /tmp/ansible-extra-vars.XXXXXX.yml)
trap 'rm -f "${EXTRA_VARS_FILE}"' EXIT

cat > "${EXTRA_VARS_FILE}" << EOF
target_host: "${JETSON_HOSTNAME}"
ansible_ssh_user: root
ansible_ssh_private_key_file: /tmp/jetson_id_rsa
ansible_become: false
EOF

# Copy ansible dir to a writable temp location (/opt/qe-rhel-jetson-ansible is read-only in CI)
ANSIBLE_DIR=$(mktemp -d /tmp/ansible.XXXXXX)
cp -r /opt/qe-rhel-jetson-ansible/. "${ANSIBLE_DIR}/"

mkdir -p "${ANSIBLE_DIR}/vars"

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

cat > "${ANSIBLE_DIR}/vars/secrets.yml" << EOF
registry_user: "${REGISTRY_USERNAME:-}"
registry_pass: "${REGISTRY_PASSWORD:-}"
EOF

$WAS_TRACING && set -x

echo "=== Connectivity check ==="
python3 -c "
import socket, sys
host = '${JETSON_HOSTNAME}'
port = 22
print(f'Testing TCP {host}:{port} ...')
s = socket.socket()
s.settimeout(10)
r = s.connect_ex((host, port))
s.close()
print('port 22 OPEN' if r == 0 else f'port 22 UNREACHABLE (errno={r})')
"
echo "==========================="

ansible-playbook \
  -i "${ANSIBLE_DIR}/inventory.yml" \
  "${ANSIBLE_DIR}/install_bootc_v3.yml" \
  -e "@${EXTRA_VARS_FILE}" \
  -e "bootc_image_base=${BOOTC_IMAGE_BASE}" \
  -e "bootc_image_tag=${BOOTC_IMAGE_TAG}" \
  -e "reservation_hours=${RESERVATION_HOURS}"
