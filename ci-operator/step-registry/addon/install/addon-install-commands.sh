#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
BREW_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/brew-token)
RUN_COMMAND="
    --cluster ${CLUSTER_NAME} \
    --token ${OCM_TOKEN} \
    --api-host ${API_HOST} \
    --timeout ${TIMEOUT} \
    --brew-token ${BREW_TOKEN} \
    "

ADDONS_CMD=""
for i in {1..4}; do
  ADDON_VALUE=$(eval "echo $"ADDON$i"_CONFIG")
  if [[ -n $ADDON_VALUE ]]; then
    ADDONS_CMD="${ADDONS_CMD} --addons ${ADDON_VALUE}"
  fi
done

echo "$ADDONS_CMD"

RUN_COMMAND="${RUN_COMMAND} ${ADDONS_CMD}"

if [ -n "${PARALLEL}" ]; then
    RUN_COMMAND="${RUN_COMMAND} --parallel"
fi

if [ -n "${ROSA}" ]; then
    RUN_COMMAND="${RUN_COMMAND} --rosa"
fi

echo "$RUN_COMMAND"

poetry run python app/cli.py addon \
    ${RUN_COMMAND} \
    install
