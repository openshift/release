#!/bin/bash

set -o nounset
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"

# Provisioning diagnostics do not require a reachable host. This also captures
# CloudFormation failures that happen before connection files can be published.
if [[ -s "${CLUSTER_PROFILE_DIR}/.awscred" ]] && command -v aws >/dev/null 2>&1; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    region="${REGION:-$LEASED_RESOURCE}"
    stack_name="${NAMESPACE}-${UNIQUE_HASH}-omr2"
    if aws --region "${region}" cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        > "${ARTIFACT_DIR}/omr-host-stack.json" 2>/dev/null; then
        aws --region "${region}" cloudformation describe-stack-events \
            --stack-name "${stack_name}" \
            > "${ARTIFACT_DIR}/omr-host-stack-events.json" 2>&1 || true
        aws --region "${region}" cloudformation describe-stack-resources \
            --stack-name "${stack_name}" \
            > "${ARTIFACT_DIR}/omr-host-stack-resources.json" 2>&1 || true
    fi
    if [[ -s "${SHARED_DIR}/omr_host_instance_id" ]]; then
        instance_id=$(<"${SHARED_DIR}/omr_host_instance_id")
        if [[ "${instance_id}" =~ ^i-[a-f0-9]+$ ]]; then
            aws --region "${region}" ec2 describe-instances \
                --instance-ids "${instance_id}" \
                > "${ARTIFACT_DIR}/omr-host-instance.json" 2>&1 || true
            aws --region "${region}" ec2 describe-instance-status \
                --include-all-instances --instance-ids "${instance_id}" \
                > "${ARTIFACT_DIR}/omr-host-instance-status.json" 2>&1 || true
            aws --region "${region}" ec2 get-console-output --latest \
                --instance-id "${instance_id}" \
                > "${ARTIFACT_DIR}/omr-host-console-output.json" 2>&1 || true
        fi
    fi
fi

rootless=false
host_address_file="${SHARED_DIR}/bastion_public_address"
host_private_file="${SHARED_DIR}/bastion_private_address"
host_user_file="${SHARED_DIR}/bastion_ssh_user"
if [[ -s "${SHARED_DIR}/omr_host_public_address" ||
      -s "${SHARED_DIR}/omr_host_ssh_user" ]]; then
    rootless=true
    host_address_file="${SHARED_DIR}/omr_host_public_address"
    host_private_file="${SHARED_DIR}/omr_host_private_address"
    host_user_file="${SHARED_DIR}/omr_host_ssh_user"
fi

if [[ ! -s "${host_address_file}" || ! -s "${host_user_file}" ]]; then
    echo "OMR host connection details are unavailable; skipping OMR diagnostics."
    exit 0
fi

if ! whoami >/dev/null 2>&1; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "Current UID has no passwd entry; skipping OMR diagnostics."
        exit 0
    fi
fi

host_address=$(<"${host_address_file}")
host_user=$(<"${host_user_file}")
host_private=""
if [[ -s "${host_private_file}" ]]; then
    host_private=$(<"${host_private_file}")
fi
ssh_options=(
    -o ConnectTimeout=30
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
)
remote="${host_user}@${host_address}"

if [[ "${rootless}" == true ]]; then
    ssh "${ssh_options[@]}" "${remote}" \
        'sudo cloud-init status --long; echo; sudo tail -n 500 /var/log/cloud-init-output.log' \
        > "${ARTIFACT_DIR}/omr-host-cloud-init.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user status quay.service quay-app.service quay-redis.service quay-pod.service --no-pager --full' \
        > "${ARTIFACT_DIR}/quay-user-service-status.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; journalctl --user -u quay.service -u quay-app.service -u quay-redis.service -u quay-pod.service --no-pager --output=short-iso' \
        > "${ARTIFACT_DIR}/quay-user-service-journal.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; podman ps --all --no-trunc; echo; podman volume ls; echo; podman images --digests --no-trunc' \
        > "${ARTIFACT_DIR}/quay-podman-state.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; for container in quay systemd-quay quay-app quay-redis; do podman inspect --format "Name={{.Name}} Image={{.ImageName}} State={{json .State}} Mounts={{json .Mounts}}" "${container}" 2>/dev/null || true; done' \
        > "${ARTIFACT_DIR}/quay-podman-inspect.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; for container in quay systemd-quay quay-app quay-redis; do echo "### ${container}"; podman logs "${container}" 2>/dev/null || true; done' \
        > "${ARTIFACT_DIR}/quay-container.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        'sudo ss -lntp; echo; df -h; echo; du -sh "$HOME/quay-install" "$HOME/quay-v3" 2>/dev/null || true' \
        > "${ARTIFACT_DIR}/quay-host-resources.log" 2>&1 || true

    if [[ -n "${host_private}" ]]; then
        ssh "${ssh_options[@]}" "${remote}" \
            "curl --silent --show-error --fail --cacert '/home/${host_user}/quay-install/quay-rootCA/rootCA.pem' 'https://${host_private}:8443/healthz'" \
            > "${ARTIFACT_DIR}/quay-health.log" 2>&1 || true
    fi
else
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo systemctl status quay.service --no-pager --full" \
        > "${ARTIFACT_DIR}/quay-service-status.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo journalctl -u quay.service --no-pager --output=short-iso" \
        > "${ARTIFACT_DIR}/quay-service-journal.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo podman ps --all --no-trunc" \
        > "${ARTIFACT_DIR}/quay-podman-state.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo podman inspect --format 'Name={{.Name}} Image={{.ImageName}} State={{json .State}} Mounts={{json .Mounts}}' quay systemd-quay" \
        > "${ARTIFACT_DIR}/quay-podman-inspect.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo podman logs quay 2>/dev/null || sudo podman logs systemd-quay 2>/dev/null" \
        > "${ARTIFACT_DIR}/quay-container.log" 2>&1 || true
    ssh "${ssh_options[@]}" "${remote}" \
        "sudo ss -lntp; echo; df -h; echo; sudo du -sh /var/lib/quay" \
        > "${ARTIFACT_DIR}/quay-host-resources.log" 2>&1 || true

    if [[ -n "${host_private}" ]]; then
        ssh "${ssh_options[@]}" "${remote}" \
            "sudo curl --silent --show-error --fail --cacert /var/lib/quay/ssl.cert 'https://${host_private}:8443/healthz'" \
            > "${ARTIFACT_DIR}/quay-health.log" 2>&1 || true
    fi
fi

echo "Best-effort OMR diagnostics collection finished."
exit 0
