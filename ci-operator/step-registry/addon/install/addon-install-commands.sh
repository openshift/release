#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME_FILENAME="${SHARED_DIR}/cluster-name"

if [ -f "$CLUSTER_NAME_FILENAME" ]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
else
  CLUSTER_NAME=""
fi

OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
BREW_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/brew-token)
CLUSTER_DATA_DIR="/tmp/clusters-data"
RUN_COMMAND="poetry run python ocp_addons_operators_cli/cli.py --action install --ocm-token ${OCM_TOKEN} "

# For multi-cluster scenarios, `cluster-name` should be passed as part of addon configuration
if [ -n "$CLUSTER_NAME" ]; then
  RUN_COMMAND+=" --cluster-name ${CLUSTER_NAME} "
fi

export AWS_CONFIG_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export OCM_TOKEN

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=$CLUSTER_DATA_DIR

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

if [ -n "${BREW_TOKEN}" ]; then
    RUN_COMMAND+=" --brew-token ${BREW_TOKEN} "
fi

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}
