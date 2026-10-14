#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# SSH requires the randomly assigned CI UID to exist in /etc/passwd.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writable, and user matching this UID is not found."
    exit 1
  fi
fi

mkdir -p "${ARTIFACT_DIR}"

if [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
  BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
elif [[ -s "${SHARED_DIR}/bastion_private_address" ]]; then
  BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
else
  echo "Bastion address was not found in SHARED_DIR; skipping diagnostics."
  exit 0
fi

BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_OPTIONS=(-o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=30)

echo "Bastion address: ${BASTION_IP}"
echo "Bastion SSH user: ${BASTION_SSH_USER}"
echo "Collecting read-only bastion connectivity diagnostics."

set +e
ssh "${SSH_OPTIONS[@]}" "${BASTION_SSH_USER}@${BASTION_IP}" 'bash -s' <<'REMOTE' | tee "${ARTIFACT_DIR}/bastion-connectivity.txt"
set +e

echo "=== identity ==="
hostname
date -u

echo "=== interfaces and routes ==="
ip -brief address
ip route

echo "=== resolver ==="
cat /etc/resolv.conf

echo "=== proxy variable presence ==="
for variable in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
  if [[ -n "${!variable:-}" ]]; then
    echo "${variable}=<set>"
  else
    echo "${variable}=<unset>"
  fi
done

echo "=== dnsmasq ==="
systemctl is-active dnsmasq
systemctl status dnsmasq --no-pager
grep -Hn "quay.io" /etc/dnsmasq.conf /etc/dnsmasq.d/* /etc/disconnected-dns.conf 2>/dev/null

echo "=== quay DNS ==="
getent hosts quay.io

echo "=== quay HTTPS ==="
if command -v curl >/dev/null 2>&1; then
  curl --connect-timeout 15 --max-time 30 --silent --show-error --output /dev/null \
    --write-out 'HTTP status: %{http_code}, remote IP: %{remote_ip}\n' https://quay.io/v2/
else
  echo "curl is not installed"
fi

echo "=== quay HTTP ==="
if command -v curl >/dev/null 2>&1; then
  curl --connect-timeout 15 --max-time 30 --silent --show-error --output /dev/null \
    --write-out 'HTTP status: %{http_code}, remote IP: %{remote_ip}\n' http://quay.io/v2/
fi
REMOTE
SSH_STATUS=${PIPESTATUS[0]}
set -e

if [[ "${SSH_STATUS}" -ne 0 ]]; then
  echo "SSH diagnostics failed with status ${SSH_STATUS}; preserving the result for inspection."
fi

echo "Diagnostics saved to ${ARTIFACT_DIR}/bastion-connectivity.txt"
exit 0
