#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
RUN_COMMAND="poetry run python app/cli.py addons --cluster ${CLUSTER_NAME} --token ${OCM_TOKEN} --api-host ${API_HOST} --timeout ${TIMEOUT} "

ADDONS_CMD=""
for i in {1..4}; do
  ADDON_VALUE=$(eval "echo $"ADDON$i"_CONFIG")
  if [[ -n $ADDON_VALUE ]]; then
    ADDONS_CMD+=" --addon ${ADDON_VALUE} "
  fi
done

RUN_COMMAND="${RUN_COMMAND} ${ADDONS_CMD}"

if [ -n "${PARALLEL}" ]; then
    RUN_COMMAND+=" --parallel"
fi

if [ -n "${ROSA}" ]; then
    RUN_COMMAND+=" --rosa"
fi

RUN_COMMAND+=" uninstall"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}
