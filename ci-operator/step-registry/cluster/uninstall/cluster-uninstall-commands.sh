#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
CLUSTER_DATA_DIR="/tmp/clusters-data"
DOCKER_CONFIG_JSON_PATH="${CLUSTER_PROFILE_DIR}/config.json"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export OCM_TOKEN
export DOCKER_CONFIG=${CLUSTER_PROFILE_DIR}

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=$CLUSTER_DATA_DIR

RUN_COMMAND="uv run openshift_cli_installer/cli.py \
            --ocm-token=$OCM_TOKEN \
            --destroy-clusters-from-install-data-directory-using-s3-bucket \
            --clusters-install-data-directory $CLUSTER_DATA_DIR"

if [ "${CLUSTERS_RUN_IN_PARALLEL}" = "true" ]; then
    RUN_COMMAND+=" --parallel"
fi

if [[ -n "${PULL_SECRET_NAME}" ]]; then
    RUN_COMMAND+=" --registry-config-file=/var/run/secrets/ci.openshift.io/cluster-profile/${PULL_SECRET_NAME} --docker-config-file ${DOCKER_CONFIG_JSON_PATH}"
fi

echo "$RUN_COMMAND" | sed -r "s/ocm-token=[A-Za-z0-9\.\-]+/ocm-token=hashed-token /g"
${RUN_COMMAND}
