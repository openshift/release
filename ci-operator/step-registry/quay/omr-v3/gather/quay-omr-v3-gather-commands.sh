#!/bin/bash

set -o nounset
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"

if [[ ! -s "${SHARED_DIR}/bastion_public_address" || ! -s "${SHARED_DIR}/bastion_ssh_user" ]]; then
    echo "Bastion connection details are unavailable; skipping OMR diagnostics."
    exit 0
fi

if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "Current uid has no passwd entry; skipping OMR diagnostics."
        exit 0
    fi
fi

bastion_address=$(<"${SHARED_DIR}/bastion_public_address")
bastion_user=$(<"${SHARED_DIR}/bastion_ssh_user")
bastion_private_dns=""
if [[ -s "${SHARED_DIR}/bastion_private_address" ]]; then
    bastion_private_dns=$(<"${SHARED_DIR}/bastion_private_address")
fi
ssh_options=(
    -o ConnectTimeout=30
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
)

remote="${bastion_user}@${bastion_address}"
ssh "${ssh_options[@]}" "${remote}" \
    "sudo systemctl status quay.service --no-pager --full" \
    > "${ARTIFACT_DIR}/quay-service-status.log" 2>&1 || true
ssh "${ssh_options[@]}" "${remote}" \
    "sudo journalctl -u quay.service --no-pager --output=short-iso" \
    > "${ARTIFACT_DIR}/quay-service-journal.log" 2>&1 || true
ssh "${ssh_options[@]}" "${remote}" \
    "sudo podman ps --all --no-trunc" \
    > "${ARTIFACT_DIR}/quay-podman-ps.log" 2>&1 || true
ssh "${ssh_options[@]}" "${remote}" \
    "sudo podman inspect quay systemd-quay" \
    > "${ARTIFACT_DIR}/quay-podman-inspect.log" 2>&1 || true
ssh "${ssh_options[@]}" "${remote}" \
    "sudo podman logs quay 2>/dev/null || sudo podman logs systemd-quay 2>/dev/null" \
    > "${ARTIFACT_DIR}/quay-container.log" 2>&1 || true
ssh "${ssh_options[@]}" "${remote}" \
    "sudo ss -lntp; echo; df -h; echo; sudo du -sh /var/lib/quay" \
    > "${ARTIFACT_DIR}/quay-host-resources.log" 2>&1 || true

if [[ -n "${bastion_private_dns}" ]]; then
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo curl --silent --show-error --fail --cacert /var/lib/quay/ssl.cert 'https://${bastion_private_dns}:8443/healthz'" \
        > "${ARTIFACT_DIR}/quay-health.log" 2>&1 || true
fi

echo "Best-effort OMR diagnostics collection finished."
exit 0
