#!/bin/bash
set -eu -o pipefail

declare NODE_SSH_PORT="${NODE_SSH_PORT:-22}"

# log emits a timestamped message to stdout. Callers must not pass internal
# network identifiers (private DNS names, IPs, security group ids) so that
# CI logs do not leak cluster topology.
log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
region="${LEASED_RESOURCE}"

infra_id="$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")"
if [[ -z "${infra_id}" || "${infra_id}" == "null" ]]; then
    log "ERROR: could not read infraID from metadata.json"
    exit 1
fi

# Worker node security group: tagged by the AWS cluster-api provider with
# role=node and the cluster's infra_id Name prefix.
worker_sg_id="$(
    aws ec2 describe-security-groups \
        --region "${region}" \
        --filters \
            "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node" \
            "Name=tag:Name,Values=${infra_id}-*" \
        --query 'SecurityGroups[0].GroupId' \
        --output text
)"
if [[ -z "${worker_sg_id}" || "${worker_sg_id}" == "None" ]]; then
    log "ERROR: could not find worker node security group"
    exit 1
fi
log "Found worker node security group"

# Bastion private IP: resolve from the bastion instance written to SHARED_DIR
# by the aws-provision-bastionhost step (bastion_private_address is its
# private DNS name; derive the private IPv4 from the instance).
bastion_private_dns="$(cat "${SHARED_DIR}/bastion_private_address" 2>/dev/null || true)"
if [[ -z "${bastion_private_dns}" ]]; then
    log "ERROR: bastion private address not found in SHARED_DIR"
    exit 1
fi

bastion_ip="$(
    aws ec2 describe-instances \
        --region "${region}" \
        --filters "Name=private-dns-name,Values=${bastion_private_dns}" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text
)"
if [[ -z "${bastion_ip}" || "${bastion_ip}" == "None" ]]; then
    log "ERROR: could not resolve bastion private IP"
    exit 1
fi
log "Resolved bastion private IP"

# Authorize SSH from the bastion to the worker nodes. Idempotent: an existing
# identical rule returns InvalidPermission.Duplicate, which we treat as success.
# The AWS error echoes the source CIDR, so it is not logged verbatim.
log "Authorizing TCP/${NODE_SSH_PORT} on the worker node security group from the bastion"
if aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${worker_sg_id}" \
    --protocol tcp \
    --port "${NODE_SSH_PORT}" \
    --cidr "${bastion_ip}/32" >/dev/null 2>/tmp/authorize_err; then
    log "Ingress rule added"
elif grep -q "InvalidPermission.Duplicate" /tmp/authorize_err; then
    log "Ingress rule already present"
else
    log "ERROR: failed to authorize SSH ingress on the worker node security group"
    exit 1
fi
