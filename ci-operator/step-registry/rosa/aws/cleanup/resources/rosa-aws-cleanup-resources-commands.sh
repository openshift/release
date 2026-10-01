#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-${LEASED_RESOURCE}}"
REGIONS="${REGIONS:-${REGION}}"
REGIONS="${REGIONS//,/ }"
read -r -a SCAN_REGIONS <<< "${REGIONS}"
export AWS_DEFAULT_REGION="${REGION}"
RESOURCE_AGE_HOURS="${RESOURCE_AGE_HOURS:-24}"
DRY_RUN="${DRY_RUN:-true}"
CLEAN_IAM="${CLEAN_IAM:-true}"

if [[ ! "${RESOURCE_AGE_HOURS}" =~ ^[0-9]+$ ]] || [[ "${RESOURCE_AGE_HOURS}" -lt 1 ]]; then
    echo "ERROR: RESOURCE_AGE_HOURS must be a positive integer"
    exit 1
fi
if [[ "${DRY_RUN}" != "true" && "${DRY_RUN}" != "false" ]]; then
    echo "ERROR: DRY_RUN must be true or false"
    exit 1
fi
if [[ "${CLEAN_IAM}" != "true" && "${CLEAN_IAM}" != "false" ]]; then
    echo "ERROR: CLEAN_IAM must be true or false"
    exit 1
fi
if [[ "${#SCAN_REGIONS[@]}" -eq 0 ]]; then
    echo "ERROR: REGIONS must contain at least one AWS region"
    exit 1
fi
if [[ "${DRY_RUN}" == "false" && "${#SCAN_REGIONS[@]}" -gt 1 ]]; then
    echo "ERROR: Multi-region scanning is only supported in dry-run mode because aws-deprovision-stacks accepts one REGION per run"
    exit 1
fi

NOW_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=$(date -u -d "${RESOURCE_AGE_HOURS} hours ago" +%s)
STACK_LIST="${SHARED_DIR}/to_be_removed_cf_stack_list"
CLEANUP_RC=0
STACK_COUNT=0
ROLE_COUNT=0
POLICY_COUNT=0
OIDC_PROVIDER_COUNT=0

# The standalone cleanup workflow owns this file. The existing
# aws-deprovision-stacks step consumes it during the workflow's post phase.
: > "${STACK_LIST}"

is_older_than_cutoff()
{
    local created_at=$1 created_epoch
    if ! created_epoch=$(date -u -d "${created_at}" +%s 2>/dev/null); then
        echo "WARNING: Could not parse resource creation time '${created_at}'" >&2
        return 1
    fi
    [[ "${created_epoch}" -le "${CUTOFF_EPOCH}" ]]
}

is_ci_iam_name()
{
    local resource_name=$1
    [[ "${resource_name}" =~ ^ci-rosa(-h|-s)?-[a-z0-9]{4}(-|$) ]]
}

run_cleanup()
{
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  DRY-RUN: aws $*"
        return 0
    fi
    if ! aws "$@"; then
        echo "WARNING: Cleanup command failed: aws $*" >&2
        CLEANUP_RC=1
        return 1
    fi
}

discover_expired_stacks()
{
    local region=$1 stacks_json
    echo "Discovering expired CI VPC stacks in ${region} ..."
    if ! stacks_json=$(aws --region "${region}" cloudformation list-stacks --output json); then
        echo "ERROR: Failed to list CloudFormation stacks in ${region}" >&2
        CLEANUP_RC=1
        return
    fi

    while IFS=$'\t' read -r stack_name created_at; do
        [[ -z "${stack_name}" ]] && continue
        if ! is_older_than_cutoff "${created_at}"; then
            continue
        fi

        local stack_json expiration_date expiration_epoch
        if ! stack_json=$(aws --region "${region}" cloudformation describe-stacks \
            --stack-name "${stack_name}" --output json); then
            echo "WARNING: Could not inspect stack ${stack_name}" >&2
            CLEANUP_RC=1
            continue
        fi
        expiration_date=$(jq -r '.Stacks[0].Tags[]? | select(.Key == "expirationDate") | .Value' <<< "${stack_json}")
        if [[ -z "${expiration_date}" || "${expiration_date}" == "null" ]]; then
            echo "Skipping ${stack_name}: missing expirationDate ownership tag"
            continue
        fi
        if ! expiration_epoch=$(date -u -d "${expiration_date}" +%s 2>/dev/null); then
            echo "WARNING: Skipping ${stack_name}: invalid expirationDate '${expiration_date}'" >&2
            CLEANUP_RC=1
            continue
        fi
        if [[ "${expiration_epoch}" -gt "${NOW_EPOCH}" ]]; then
            echo "Skipping ${stack_name}: expirationDate has not passed"
            continue
        fi

        echo "Found expired CI VPC stack ${stack_name} in ${region} (created ${created_at})"
        STACK_COUNT=$((STACK_COUNT + 1))
        if [[ "${DRY_RUN}" == "false" ]]; then
            echo "${stack_name}" >> "${STACK_LIST}"
        fi
    done < <(jq -r '
        .StackSummaries[]
        | select(.StackStatus != "DELETE_COMPLETE")
        | select((.StackStatus | endswith("_IN_PROGRESS")) | not)
        | select(.StackName | test("^ci-op-[a-z0-9]+-[a-z0-9]+-vpc$"))
        | [.StackName, .CreationTime]
        | @tsv
    ' <<< "${stacks_json}")
}

cleanup_role()
{
    local role_name=$1 attached_policies inline_policies instance_profiles
    echo "Cleaning expired CI IAM role ${role_name} ..."

    if attached_policies=$(aws iam list-attached-role-policies --role-name "${role_name}" \
        --query 'AttachedPolicies[].PolicyArn' --output text); then
        for policy_arn in ${attached_policies}; do
            [[ "${policy_arn}" == "None" ]] && continue
            run_cleanup iam detach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" || true
        done
    else
        CLEANUP_RC=1
    fi

    if inline_policies=$(aws iam list-role-policies --role-name "${role_name}" \
        --query 'PolicyNames[]' --output text); then
        for policy_name in ${inline_policies}; do
            [[ "${policy_name}" == "None" ]] && continue
            run_cleanup iam delete-role-policy --role-name "${role_name}" --policy-name "${policy_name}" || true
        done
    else
        CLEANUP_RC=1
    fi

    if instance_profiles=$(aws iam list-instance-profiles-for-role --role-name "${role_name}" \
        --query 'InstanceProfiles[].InstanceProfileName' --output text); then
        for profile_name in ${instance_profiles}; do
            [[ "${profile_name}" == "None" ]] && continue
            run_cleanup iam remove-role-from-instance-profile \
                --instance-profile-name "${profile_name}" --role-name "${role_name}" || true
            run_cleanup iam delete-instance-profile --instance-profile-name "${profile_name}" || true
        done
    else
        CLEANUP_RC=1
    fi

    run_cleanup iam delete-role --role-name "${role_name}" || true
}

iam_principal_is_expired()
{
    local principal_type=$1 principal_name=$2 created_at

    if ! is_ci_iam_name "${principal_name}"; then
        return 1
    fi

    case "${principal_type}" in
        Role)
            if ! created_at=$(aws iam get-role --role-name "${principal_name}" \
                --query 'Role.CreateDate' --output text); then
                echo "WARNING: Could not classify attached IAM role ${principal_name}; treating it as retained" >&2
                CLEANUP_RC=1
                return 1
            fi
            ;;
        User)
            if ! created_at=$(aws iam get-user --user-name "${principal_name}" \
                --query 'User.CreateDate' --output text); then
                echo "WARNING: Could not classify attached IAM user ${principal_name}; treating it as retained" >&2
                CLEANUP_RC=1
                return 1
            fi
            ;;
        Group)
            if ! created_at=$(aws iam get-group --group-name "${principal_name}" \
                --query 'Group.CreateDate' --output text); then
                echo "WARNING: Could not classify attached IAM group ${principal_name}; treating it as retained" >&2
                CLEANUP_RC=1
                return 1
            fi
            ;;
        *)
            echo "WARNING: Unknown IAM principal type ${principal_type}; treating ${principal_name} as retained" >&2
            CLEANUP_RC=1
            return 1
            ;;
    esac

    if [[ -z "${created_at}" || "${created_at}" == "None" ]]; then
        echo "WARNING: IAM ${principal_type} ${principal_name} has no creation time; treating it as retained" >&2
        CLEANUP_RC=1
        return 1
    fi
    is_older_than_cutoff "${created_at}"
}

cleanup_policy()
{
    local policy_name=$1 policy_arn=$2 roles users groups versions
    local has_retained_attachment=false

    if ! roles=$(aws iam list-entities-for-policy --policy-arn "${policy_arn}" \
        --entity-filter Role --query 'PolicyRoles[].RoleName' --output text); then
        CLEANUP_RC=1
        return
    fi
    if ! users=$(aws iam list-entities-for-policy --policy-arn "${policy_arn}" \
        --entity-filter User --query 'PolicyUsers[].UserName' --output text); then
        CLEANUP_RC=1
        return
    fi
    if ! groups=$(aws iam list-entities-for-policy --policy-arn "${policy_arn}" \
        --entity-filter Group --query 'PolicyGroups[].GroupName' --output text); then
        CLEANUP_RC=1
        return
    fi

    # Classify every attachment before changing any of them. If one principal
    # is retained or cannot be classified, retain the policy and all remaining
    # attachments.
    for role_name in ${roles}; do
        [[ "${role_name}" == "None" ]] && continue
        if ! iam_principal_is_expired Role "${role_name}"; then
            echo "IAM policy ${policy_name} has retained attached role ${role_name}"
            has_retained_attachment=true
        fi
    done
    for user_name in ${users}; do
        [[ "${user_name}" == "None" ]] && continue
        if ! iam_principal_is_expired User "${user_name}"; then
            echo "IAM policy ${policy_name} has retained attached user ${user_name}"
            has_retained_attachment=true
        fi
    done
    for group_name in ${groups}; do
        [[ "${group_name}" == "None" ]] && continue
        if ! iam_principal_is_expired Group "${group_name}"; then
            echo "IAM policy ${policy_name} has retained attached group ${group_name}"
            has_retained_attachment=true
        fi
    done
    if [[ "${has_retained_attachment}" == "true" ]]; then
        echo "Skipping expired CI IAM policy ${policy_name}: one or more attached principals are retained"
        return
    fi

    echo "Cleaning expired CI IAM policy ${policy_name} ..."
    for role_name in ${roles}; do
        [[ "${role_name}" == "None" ]] && continue
        run_cleanup iam detach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}" || true
    done
    for user_name in ${users}; do
        [[ "${user_name}" == "None" ]] && continue
        run_cleanup iam detach-user-policy --user-name "${user_name}" --policy-arn "${policy_arn}" || true
    done
    for group_name in ${groups}; do
        [[ "${group_name}" == "None" ]] && continue
        run_cleanup iam detach-group-policy --group-name "${group_name}" --policy-arn "${policy_arn}" || true
    done

    if versions=$(aws iam list-policy-versions --policy-arn "${policy_arn}" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); then
        for version_id in ${versions}; do
            [[ "${version_id}" == "None" ]] && continue
            run_cleanup iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${version_id}" || true
        done
    else
        CLEANUP_RC=1
    fi

    run_cleanup iam delete-policy --policy-arn "${policy_arn}" || true
}

oidc_provider_has_retained_role()
{
    local provider_arn=$1 roles_json=$2 ignore_expired_ci_roles=$3
    local role_json role_name created_at

    while read -r role_json; do
        role_name=$(jq -r '.RoleName' <<< "${role_json}")
        created_at=$(jq -r '.CreateDate' <<< "${role_json}")
        if [[ "${ignore_expired_ci_roles}" == "true" ]] && \
            is_ci_iam_name "${role_name}" && is_older_than_cutoff "${created_at}"; then
            continue
        fi
        if jq -e --arg provider_arn "${provider_arn}" '
            [
                .AssumeRolePolicyDocument.Statement[]?.Principal.Federated?
                | if type == "array" then .[] else . end
            ]
            | index($provider_arn) != null
        ' <<< "${role_json}" >/dev/null; then
            echo "Skipping ${provider_arn}: trusted by retained IAM role ${role_name}"
            return 0
        fi
    done < <(jq -c '.Roles[]' <<< "${roles_json}")
    return 1
}

cleanup_expired_oidc_providers()
{
    local roles_json=$1 ignore_expired_ci_roles=$2
    local providers_json provider_json provider_arn created_at provider_url managed_tag_count
    echo "Discovering expired ROSA-managed IAM OIDC providers ..."
    if ! providers_json=$(aws iam list-open-id-connect-providers --output json); then
        echo "ERROR: Failed to list IAM OIDC providers" >&2
        CLEANUP_RC=1
        return
    fi

    while read -r provider_arn; do
        [[ -z "${provider_arn}" ]] && continue
        if ! provider_json=$(aws iam get-open-id-connect-provider \
            --open-id-connect-provider-arn "${provider_arn}" --output json); then
            echo "WARNING: Could not inspect IAM OIDC provider ${provider_arn}" >&2
            CLEANUP_RC=1
            continue
        fi

        managed_tag_count=$(jq '[.Tags[]? | select(.Key == "red-hat-managed" and .Value == "true")] | length' \
            <<< "${provider_json}")
        if [[ "${managed_tag_count}" -eq 0 ]]; then
            continue
        fi
        created_at=$(jq -r '.CreateDate // empty' <<< "${provider_json}")
        if [[ -z "${created_at}" ]] || ! is_older_than_cutoff "${created_at}"; then
            continue
        fi
        if oidc_provider_has_retained_role \
            "${provider_arn}" "${roles_json}" "${ignore_expired_ci_roles}"; then
            continue
        fi

        provider_url=$(jq -r '.Url // "unknown"' <<< "${provider_json}")
        echo "Cleaning expired ROSA-managed IAM OIDC provider ${provider_url} ..."
        OIDC_PROVIDER_COUNT=$((OIDC_PROVIDER_COUNT + 1))
        run_cleanup iam delete-open-id-connect-provider \
            --open-id-connect-provider-arn "${provider_arn}" || true
    done < <(jq -r '.OpenIDConnectProviderList[]?.Arn' <<< "${providers_json}")
}

cleanup_expired_iam()
{
    local roles_json policies_json oidc_roles_json ignore_expired_ci_roles
    echo "Discovering expired ROSA CI IAM roles and policies ..."
    if ! roles_json=$(aws iam list-roles --output json); then
        echo "ERROR: Failed to list IAM roles" >&2
        CLEANUP_RC=1
        return
    fi
    while IFS=$'\t' read -r role_name created_at; do
        [[ -z "${role_name}" ]] && continue
        if is_ci_iam_name "${role_name}" && is_older_than_cutoff "${created_at}"; then
            ROLE_COUNT=$((ROLE_COUNT + 1))
            cleanup_role "${role_name}"
        fi
    done < <(jq -r '.Roles[] | [.RoleName, .CreateDate] | @tsv' <<< "${roles_json}")

    if ! policies_json=$(aws iam list-policies --scope Local --output json); then
        echo "ERROR: Failed to list customer-managed IAM policies" >&2
        CLEANUP_RC=1
        return
    fi
    while IFS=$'\t' read -r policy_name policy_arn created_at; do
        [[ -z "${policy_name}" ]] && continue
        if is_ci_iam_name "${policy_name}" && is_older_than_cutoff "${created_at}"; then
            POLICY_COUNT=$((POLICY_COUNT + 1))
            cleanup_policy "${policy_name}" "${policy_arn}"
        fi
    done < <(jq -r '.Policies[] | [.PolicyName, .Arn, .CreateDate] | @tsv' <<< "${policies_json}")

    # Remove providers after roles. In a live cleanup, refresh the role list so
    # a role that failed deletion still protects the provider it trusts. During
    # a dry run, model eligible expired CI roles as deleted.
    oidc_roles_json=${roles_json}
    ignore_expired_ci_roles=true
    if [[ "${DRY_RUN}" == "false" ]]; then
        if ! oidc_roles_json=$(aws iam list-roles --output json); then
            echo "ERROR: Failed to refresh IAM roles before OIDC provider cleanup" >&2
            CLEANUP_RC=1
            return
        fi
        ignore_expired_ci_roles=false
    fi
    cleanup_expired_oidc_providers "${oidc_roles_json}" "${ignore_expired_ci_roles}"
}

echo "Scanning AWS account for ROSA CI resources older than ${RESOURCE_AGE_HOURS} hours in regions: ${SCAN_REGIONS[*]} (dry-run: ${DRY_RUN})"
for scan_region in "${SCAN_REGIONS[@]}"; do
    discover_expired_stacks "${scan_region}"
done
if [[ "${CLEAN_IAM}" == "true" ]]; then
    cleanup_expired_iam
fi

echo "Cleanup candidates: ${STACK_COUNT} CloudFormation stack(s), ${ROLE_COUNT} IAM role(s), ${POLICY_COUNT} IAM policy/policies, ${OIDC_PROVIDER_COUNT} IAM OIDC provider(s)"
exit "${CLEANUP_RC}"
