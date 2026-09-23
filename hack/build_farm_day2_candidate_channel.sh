#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Illegal number of parameters"
  exit 1
fi

CLUSTER=$1
readonly CLUSTER

echo "Checking Upgrade Channel on ${CLUSTER}"

ID=$(ocm list cluster ${CLUSTER} --columns id --no-headers)
readonly ID

if [[ -z "${ID}" ]]; then
  echo "failed to find ID of the cluster ${CLUSTER}"
  exit 1
fi

CURRENT_CHANNEL_GROUP=$(ocm get cluster ${ID} | jq -r '.version.channel_group')
readonly CURRENT_CHANNEL_GROUP

if [[ "$CURRENT_CHANNEL_GROUP" == "candidate" ]]; then
    echo "${CLUSTER} has been using the candidate channel already, Skipping ..."
    exit
fi

echo "Configuring channel group on ${CLUSTER}"
echo '{"version":{"channel_group":"candidate"}}' | ocm patch cluster "${ID}"
