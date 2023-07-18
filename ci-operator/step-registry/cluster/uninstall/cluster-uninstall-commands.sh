#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export OCM_TOKEN

RUN_COMMAND="poetry run python app/cli.py --action destroy --clusters-install-data-directory ${SHARED_DIR}/clusters-data  --ocm-token=$OCM_TOKEN "

CLUSTERS_CMD=""
NUM_CLUSTERS=0
for cluster_value in $(env | grep -E '^CLUSTER[0-9]+_CONFIG' | sort  --version-sort); do
    cluster_value=$(echo "$cluster_value" | sed -E  's/^CLUSTER[0-9]+_CONFIG=//')
    if  [ "${cluster_value}" ]; then
      CLUSTERS_CMD+=" --cluster ${cluster_value} "
      NUM_CLUSTERS=$(( NUM_CLUSTERS + 1))
    fi
done

RUN_COMMAND+="${CLUSTERS_CMD} "

if [[ -n "${OCM_ENVIRONMENT}" ]]; then
    RUN_COMMAND+=" --ocm-env=${OCM_ENVIRONMENT} "
fi

if [ "${PARALLEL}" = "true" ] && [ $NUM_CLUSTERS -gt 1 ]; then
    RUN_COMMAND+=" --parallel"
fi

if [[ -n "${S3_BUCKET_NAME}" ]]; then
    RUN_COMMAND+=" --s3-bucket-name=${S3_BUCKET_NAME} "
fi

if [[ -n "${S3_BUCKET_PATH}" ]]; then
    RUN_COMMAND+=" --s3-bucket-path=${S3_BUCKET_PATH} "
fi

if [[ -n "${PULL_SECRET_NAME}" ]]; then
    RUN_COMMAND+=" --pull-secret-file=/var/run/secrets/ci.openshift.io/cluster-profile/${PULL_SECRET_NAME} "
fi

echo "$RUN_COMMAND" | sed -r "s/ocm-token=[A-Za-z0-9\.\-]+/ocm-token=hashed-token /g"

${RUN_COMMAND}
