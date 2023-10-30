#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

# Delete rule group
RULE_GROUP_ARN_FILE="${SHARED_DIR}/firewall_rule_group_arn"
if [[ -e "${RULE_GROUP_ARN_FILE}" ]]; then
  rule_group_arn=$(cat "${RULE_GROUP_ARN_FILE}")

  echo "Remove the network firewall rule group $rule_group_arn"
  aws --region $REGION network-firewall delete-rule-group --rule-group-arn $rule_group_arn
else
  echo "No network firewall rule group created in the pre step"
fi

echo "Finish the network firewall rule group deletion."

