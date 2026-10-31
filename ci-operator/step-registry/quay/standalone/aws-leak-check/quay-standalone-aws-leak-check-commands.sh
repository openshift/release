#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -s "${SHARED_DIR}/quay_standalone_job_tag" ]]; then
    echo "No quay_standalone_job_tag in SHARED_DIR: quay-standalone-aws-infra never ran, nothing to check."
    exit 0
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
region=$(<"${SHARED_DIR}/quay_standalone_region")
job_tag=$(<"${SHARED_DIR}/quay_standalone_job_tag")
stack_name=$(<"${SHARED_DIR}/quay_standalone_stack_name")
db_identifier=$(<"${SHARED_DIR}/quay_standalone_db_identifier")
bucket=$(<"${SHARED_DIR}/quay_standalone_s3_bucket")
hostnames=()
for name in quay_standalone_hostname quay_standalone_clair_hostname; do
    if [[ -s "${SHARED_DIR}/${name}" ]]; then
        hostnames+=("$(<"${SHARED_DIR}/${name}")")
    fi
done

err_file=$(mktemp)
trap 'rm -f -- "${err_file}"' EXIT
failures=0

report() {
    echo "LEFT: $*" >&2
    failures=$((failures + 1))
}

# Prints the command's output. An error matching the not-found pattern $1 means
# the resource is gone and prints nothing; any other error fails the lookup,
# because it proves nothing about whether the resource is left.
lookup() {
    local not_found=$1
    shift
    if "$@" 2>"${err_file}"; then
        return 0
    fi
    if [[ -n "${not_found}" ]] && grep -q -- "${not_found}" "${err_file}"; then
        return 0
    fi
    cat "${err_file}" >&2
    return 1
}

if ! stack=$(lookup 'does not exist' aws --region "${region}" cloudformation describe-stacks \
    --stack-name "${stack_name}" --query 'Stacks[0].[StackId,StackStatus]' --output text); then
    report "could not check CloudFormation stack ${stack_name}"
elif [[ -n "${stack}" && "${stack}" != *DELETE_COMPLETE ]]; then
    report "CloudFormation stack ${stack}"
fi

if ! instances=$(lookup '' aws --region "${region}" ec2 describe-instances \
    --filters "Name=tag:quay-standalone-job,Values=${job_tag}" \
        'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped' \
    --query 'Reservations[].Instances[].InstanceId' --output text); then
    report "could not list EC2 instances tagged quay-standalone-job=${job_tag}"
elif [[ -n "${instances}" ]]; then
    report "EC2 instances ${instances}"
fi

if ! db=$(lookup 'DBInstanceNotFound' aws --region "${region}" rds describe-db-instances \
    --db-instance-identifier "${db_identifier}" \
    --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus]' --output text); then
    report "could not check RDS instance ${db_identifier}"
elif [[ -n "${db}" ]]; then
    report "RDS instance ${db}"
fi

if aws --region "${region}" s3api head-bucket --bucket "${bucket}" >/dev/null 2>"${err_file}"; then
    report "S3 bucket ${bucket}"
elif ! grep -q -- '(404)' "${err_file}"; then
    cat "${err_file}" >&2
    report "could not check S3 bucket ${bucket}"
fi

# The NLB ARNs are not published; their DNS names are, once the stack was
# created. Without them the stack check above covers the NLBs.
for hostname in "${hostnames[@]}"; do
    if ! nlb=$(lookup '' aws --region "${region}" elbv2 describe-load-balancers \
        --query "LoadBalancers[?DNSName=='${hostname}'].LoadBalancerArn" --output text); then
        report "could not list load balancers for ${hostname}"
    elif [[ -n "${nlb}" ]]; then
        report "NLB ${nlb}"
    fi
done

if (( failures > 0 )); then
    echo "Quay standalone job ${job_tag} left ${failures} AWS resource(s) or unchecked lookups behind." >&2
    exit 1
fi
echo "No AWS resources left for Quay standalone job ${job_tag}."
