#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
RUN_COMMAND="poetry run python ocp_addons_operators_cli/cli.py addons --cluster ${CLUSTER_NAME} --token ${OCM_TOKEN} --api-host ${API_HOST} "
export AWS_CONFIG_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export OCM_TOKEN

ADDONS_CMD=""
for addon_value in $(env | grep -E '^ADDON[0-9]+_CONFIG' | sort  --version-sort); do
    addon_value=$(echo "$addon_value" | sed -E  's/^ADDON[0-9]+_CONFIG=//')
    if  [ "${addon_value}" ]; then
      ADDONS_CMD+=" --addon ${addon_value} "
    fi
done

RUN_COMMAND="${RUN_COMMAND} ${ADDONS_CMD}"

if [ "${ADDONS_OPERATORS_RUN_IN_PARALLEL}" = "true" ]; then
    RUN_COMMAND+=" --parallel"
fi

RUN_COMMAND+=" uninstall"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}
