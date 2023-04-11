#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# get AWS region
REGION="${LEASED_RESOURCE}"

echo "************ single-node test command ************"

# Tests execution
set +e

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

NODE_NAME=`oc get node  |grep master | awk '{print $1}'`
Instance_Type=`aws ec2 describe-instances --region ${REGION} --filters "Name=private-dns-name,Values=${NODE_NAME}" --query "Reservations[*].Instances[*].[InstanceType]"`

if [[ "${Instance_Type}" == "m6i.2xlarge" ]]; then
  echo "The installer defaults for Single Node AWS have taken effect, is ${Instance_Type}"
else
  echo "The installer defaults for Single Node AWS not in effect"
  exit 1
fi

rv=$?

set -e
echo "### Done! (${rv})"
exit $rv
