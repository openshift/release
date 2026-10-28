#!/bin/bash

# Best effort: every input may be missing when infra failed early, and no
# gather failure may fail the job.
set -o nounset
set -o pipefail

out="${ARTIFACT_DIR}/quay-standalone"
mkdir -p "${out}"

# Prints a SHARED_DIR value, or nothing when the file is missing.
shared() {
    if [[ -s "${SHARED_DIR}/$1" ]]; then
        cat "${SHARED_DIR}/$1"
    fi
}

region=$(shared quay_standalone_region)
region="${region:-${REGION:-${LEASED_RESOURCE:-}}}"
ssh_user=$(shared quay_standalone_ssh_user)
ssh_user="${ssh_user:-ec2-user}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Masks the database passwords and the Clair PSK should a log quote DB_URI,
# a Clair connstring or the PSK. They are hex, so they are safe as sed
# patterns; anything else is not used as one. Tracing stays off for the rest
# of the step, since every redact call expands them.
set +x
redactions=()
for secret_file in quay_standalone_db_password quay_standalone_clair_db_password quay_standalone_clair_psk; do
    secret=$(shared "${secret_file}")
    if [[ "${secret}" =~ ^[A-Za-z0-9]+$ ]]; then
        redactions+=(-e "s/${secret}/REDACTED/g")
    fi
done
unset secret
redact() {
    if (( ${#redactions[@]} > 0 )); then
        sed "${redactions[@]}"
    else
        cat
    fi
}

if ! whoami >/dev/null 2>&1 && [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
fi

ssh_options=(
    -n
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o BatchMode=yes
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
    -o ConnectTimeout=10
    -o ConnectionAttempts=1
)

# gather_host DIR IP NAME COMMAND [NAME COMMAND...]: one file per command.
# Never add a command that reads the config bundle, keys or the pull auth.
gather_host() {
    local dir=$1 ip=$2

    shift 2
    mkdir -p "${dir}"
    if ! timeout 60 ssh "${ssh_options[@]}" "${ssh_user}@${ip}" true >/dev/null 2>&1; then
        echo "${ip} is unreachable over SSH (a node stopped by failover is expected to be)." \
            | tee "${dir}/unreachable.txt"
        return 0
    fi
    while (( $# >= 2 )); do
        timeout 120 ssh "${ssh_options[@]}" "${ssh_user}@${ip}" "$2" 2>&1 | redact > "${dir}/$1.txt"
        shift 2
    done
}

if [[ -s "${SHARED_DIR}/quay_standalone_nodes" ]]; then
    mapfile -t nodes < "${SHARED_DIR}/quay_standalone_nodes"
    for index in "${!nodes[@]}"; do
        read -r instance_id public_ip _ <<< "${nodes[${index}]}"
        echo "Gathering Quay node $((index + 1)) (${instance_id})..."
        clair=()
        if (( index < 2 )); then
            clair=(podman-logs-clair 'sudo podman logs --tail 5000 clair')
        fi
        gather_host "${out}/quay-$((index + 1))-${instance_id}" "${public_ip}" \
            podman-ps 'sudo podman ps -a' \
            podman-logs-quay 'sudo podman logs --tail 5000 quay' \
            "${clair[@]}" \
            journal-cloud-final 'sudo journalctl -u cloud-final --no-pager'
    done
fi

if [[ -s "${SHARED_DIR}/quay_standalone_redis" ]]; then
    read -r instance_id public_ip _ < "${SHARED_DIR}/quay_standalone_redis"
    echo "Gathering the Redis host (${instance_id})..."
    gather_host "${out}/redis-${instance_id}" "${public_ip}" \
        systemctl-status-redis 'sudo systemctl status redis --no-pager' \
        journal-redis 'sudo journalctl -u redis --no-pager' \
        journal-cloud-final 'sudo journalctl -u cloud-final --no-pager'
fi

if [[ -n "${region}" ]]; then
    target_group_arn=$(shared quay_standalone_target_group_arn)
    if [[ -n "${target_group_arn}" ]]; then
        aws --region "${region}" elbv2 describe-target-health --target-group-arn "${target_group_arn}" \
            --output json > "${out}/nlb-target-health.json" 2>&1
    fi
    db_identifier=$(shared quay_standalone_db_identifier)
    if [[ -n "${db_identifier}" ]]; then
        aws --region "${region}" rds describe-db-instances --db-instance-identifier "${db_identifier}" \
            --output json > "${out}/rds-db-instance.json" 2>&1
    fi
    stack_name=$(shared quay_standalone_stack_name)
    if [[ -n "${stack_name}" ]]; then
        aws --region "${region}" cloudformation describe-stack-events --stack-name "${stack_name}" \
            --output json > "${out}/stack-events.json" 2>&1
    fi
fi

exit 0
