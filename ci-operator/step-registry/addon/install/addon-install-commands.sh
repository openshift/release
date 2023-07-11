#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
BREW_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/brew-token)
RUN_COMMAND="poetry run python app/cli.py addons --cluster ${CLUSTER_NAME} --token ${OCM_TOKEN} --api-host ${API_HOST} "
export OCM_TOKEN

# Modify temp aws config file with defaulted region variable
# TODO AWS_REGION set
AWS_REGION=$LEASED_RESOURCE
export AWS_CONFIG_FILE="/tmp/.aws_config"
cat "${CLUSTER_PROFILE_DIR}/.awscred" >> $AWS_CONFIG_FILE
echo $AWS_REGION >> $AWS_CONFIG_FILE


ADDONS_CMD=""
for addon_value in $(env | grep -E '^ADDON[0-9]+_CONFIG' | sort  --version-sort); do
    addon_value=$(echo "$addon_value" | sed -E  's/^ADDON[0-9]+_CONFIG=//')
    if  [ "${addon_value}" ]; then
      ADDONS_CMD+=" --addon ${addon_value} "
    fi
done

RUN_COMMAND="${RUN_COMMAND} ${ADDONS_CMD}"

if [ "${PARALLEL}" = "true" ]; then
    RUN_COMMAND+=" --parallel"
fi

if [ -n "${BREW_TOKEN}" ]; then
    RUN_COMMAND+=" --brew-token ${BREW_TOKEN} "
fi

RUN_COMMAND+=" install"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

sleep 1h
${RUN_COMMAND}
