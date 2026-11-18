#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

if [ ! -f "${SHARED_DIR}/cluster_name" ]; then
  echo "No cluster name; nothing to destroy."
  exit 0
fi
[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
OVE_ISO_STORAGE_HOST=""
if [ -f "${CLUSTER_PROFILE_DIR}/ove_iso_storage_host" ]; then
  OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
fi
WORK_DIR="/var/lib/assisted/${CLUSTER_NAME}"

timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "WORK_DIR=$(printf '%q' "${WORK_DIR}") CLUSTER_NAME=$(printf '%q' "${CLUSTER_NAME}") OVE_ISO_STORAGE_HOST=$(printf '%q' "${OVE_ISO_STORAGE_HOST}") bash -s" <<'EOF'
set -o errexit
set -o pipefail
set -o nounset

if [ ! -d "${WORK_DIR}" ]; then
  echo "Assisted work directory is absent."
else
  if [ -f "${WORK_DIR}/iso-http.pid" ]; then
    http_pid=$(<"${WORK_DIR}/iso-http.pid")
    if [ -n "${http_pid}" ]; then
      kill "${http_pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${http_pid}" 2>/dev/null || true
    fi
  fi
  if [ -f "${WORK_DIR}/runtime.env" ]; then
    # shellcheck disable=SC1091
    source "${WORK_DIR}/runtime.env"
    if [ -n "${POD_NAME:-}" ]; then
      podman pod rm --force --ignore "${POD_NAME}" || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      [ -n "${ISO_PORT:-}" ] && firewall-cmd --quiet --remove-port="${ISO_PORT}/tcp" || true
      [ -n "${SERVICE_PORT:-}" ] && firewall-cmd --quiet --remove-port="${SERVICE_PORT}/tcp" || true
      [ -n "${IMAGE_PORT:-}" ] && firewall-cmd --quiet --remove-port="${IMAGE_PORT}/tcp" || true
    fi
  fi
  rm -rf "${WORK_DIR}"
fi

if [ -z "${OVE_ISO_STORAGE_HOST}" ]; then
  echo "ISO storage host is unknown; leaving any discovery ISO in place."
  exit 0
fi
CONTAINER_NAME="haproxy-${CLUSTER_NAME}"
if ! podman inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Load balancer is already gone; leaving any discovery ISO in place."
  exit 0
fi
nsenter -n -t "$(podman inspect -f '{{ .State.Pid }}' "${CONTAINER_NAME}")" \
  ssh -o StrictHostKeyChecking=no root@"${OVE_ISO_STORAGE_HOST}" \
  "rm -f /var/mnt/data-storage/html/${CLUSTER_NAME}.discovery.iso"
echo "Removed the discovery ISO."
EOF
