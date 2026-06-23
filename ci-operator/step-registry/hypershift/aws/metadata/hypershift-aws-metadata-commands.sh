#!/usr/bin/env bash

set -e
set -u
set -x
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}

vpc_id="$(oc get hc -A -o jsonpath='{.items[0].spec.platform.aws.cloudProviderConfig.vpc}')"
if [[ -z "${vpc_id}" || "${vpc_id}" == "null" ]]; then
    echo "Error: HostedCluster VPC ID not found." >&2
    exit 1
fi

infra_id="$(oc get hc -A -o jsonpath='{.items[0].spec.infraID}')"
if [[ -z "${infra_id}" || "${infra_id}" == "null" ]]; then
    echo "Error: HostedCluster infraID not found." >&2
    exit 1
fi

public_subnet="$(aws --region "${REGION}" ec2 describe-subnets --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" "Name=tag:Name,Values=*public*" --query 'Subnets[0].SubnetId' --output text)"
if [[ -z "${public_subnet}" || "${public_subnet}" == "None" || "${public_subnet}" == "null" ]]; then
    echo "Error: Public subnet ID lookup failed for infraID ${infra_id} in region ${REGION}." >&2
    exit 1
fi

if [[ -f "${SHARED_DIR}/vpc_id" ]]; then
    echo "Error: The file ${SHARED_DIR}/vpc_id already exists. Operation aborted to prevent overwriting."
    exit 1
fi
if [[ -f "${SHARED_DIR}/public_subnet_ids" ]]; then
    echo "Error: The file ${SHARED_DIR}/public_subnet_ids already exists. Operation aborted to prevent overwriting."
    exit 1
fi
echo "$vpc_id" > "${SHARED_DIR}/vpc_id"
echo "- $public_subnet" > "${SHARED_DIR}/public_subnet_ids"
