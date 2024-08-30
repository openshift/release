#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ ${ENABLE_SHARED_PHZ} == "yes" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
else
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

REGION="${LEASED_RESOURCE}"
HOSTED_ZONE_ID="${SHARED_DIR}/hosted_zone_id"

if [ ! -f "${HOSTED_ZONE_ID}" ]; then
  echo "File ${HOSTED_ZONE_ID} does not exist."
  exit 1
fi

function aws_delete_role() 
{
    local aws_region=$1
    local role_name=$2
    local policy_arn attached_policies inline_policies policy_name

    echo -e "deleteing role: $role_name"
    # detach policy
    attached_policies=$(aws --region $aws_region iam list-attached-role-policies --role-name ${role_name} | jq -r .AttachedPolicies[].PolicyArn)
    echo -e "getting policies ..."
    for policy_arn in $attached_policies;
    do
        if [ X"$policy_arn" == X"" ]; then
            continue
        fi 
        echo -e "detaching policy: ${policy_arn}"
        aws --region $aws_region iam detach-role-policy --role-name ${role_name} --policy-arn ${policy_arn} || return 1
    done

    # delete inline policy
    inline_policies=$(aws --region $aws_region iam list-role-policies --role-name ${role_name} | jq -r .PolicyNames[])
    for policy_name in $inline_policies;
    do
        if [ X"$policy_name" == X"" ]; then
            continue
        fi 
        echo -e "deleting inline policy: ${policy_name}"
        aws --region $aws_region iam delete-role-policy --role-name ${role_name} --policy-name ${policy_name} || return 1
    done
    
    echo -e "deleting role: ${role_name}"
    aws --region $aws_region iam delete-role --role-name ${role_name} || return 1

    return 0
}

echo "Deleting AWS route53 hosted zone"
HOSTED_ZONE="$(aws --region "${REGION}" route53 delete-hosted-zone --id  "$(cat "${HOSTED_ZONE_ID}")")"
CHANGE_ID="$(echo "${HOSTED_ZONE}" | jq -r '.ChangeInfo.Id' | awk -F / '{printf $3}')"

# add a sleep time to reduce Rate exceeded errors
sleep 120

aws --region "${REGION}" route53 wait resource-record-sets-changed --id "${CHANGE_ID}" &
wait "$!"
echo "AWS route53 hosted zone $(cat "${HOSTED_ZONE_ID}") successfully deleted."


if [[ ${ENABLE_SHARED_PHZ} == "yes" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

  role_name=$(head -n 1 ${SHARED_DIR}/shared_install_role_name)
  shared_policy_arn=$(head -n 1 ${SHARED_DIR}/shared_install_policy_arn)

  aws_delete_role $REGION ${role_name}
  echo "Deleted role: ${role_name}"

  echo "Deleting policy: ${shared_policy_arn}"
  aws --region "$REGION" iam delete-policy --policy-arn "${shared_policy_arn}"
  echo "Deleted policy: ${shared_policy_arn}"

fi
