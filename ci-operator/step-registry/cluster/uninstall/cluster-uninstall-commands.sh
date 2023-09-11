#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
CLUSTER_DATA_DIR="/tmp/clusters-data"
DATA_FILENAME="cluster_data.yaml"
DOCKER_CONFIG_JSON_PATH="${CLUSTER_PROFILE_DIR}/config.json"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export OCM_TOKEN
export DOCKER_CONFIG=${CLUSTER_PROFILE_DIR}

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=$CLUSTER_DATA_DIR

RUN_COMMAND="poetry run python openshift_cli_installer/cli.py \
            --ocm-token=$OCM_TOKEN \
            --s3-bucket-name=$S3_BUCKET_NAME "

CLUSTER_DATA_FILES=$(find $CLUSTER_DATA_DIR -name $DATA_FILENAME)
if [ -z "${CLUSTER_DATA_FILES}" ] ; then
  echo "No ${DATA_FILENAME} files found under ${CLUSTER_DATA_DIR}"
  exit 1
fi

CLUSTER_DATA_CMD="--destroy-clusters-from-s3-config-files "
for data_file in $CLUSTER_DATA_FILES; do
  CLUSTER_DATA_CMD+="${data_file},"
done

RUN_COMMAND+=$(echo "${CLUSTER_DATA_CMD}" | sed 's/,$//g')

if [[ -n "${S3_BUCKET_PATH}" ]]; then
    RUN_COMMAND+=" --s3-bucket-path=${S3_BUCKET_PATH} "
fi

if [[ -n "${PULL_SECRET_NAME}" ]]; then
    RUN_COMMAND+=" --registry-config-file=/var/run/secrets/ci.openshift.io/cluster-profile/${PULL_SECRET_NAME} --docker-config-file ${DOCKER_CONFIG_JSON_PATH}"
fi

echo "$RUN_COMMAND" | sed -r "s/ocm-token=[A-Za-z0-9\.\-]+/ocm-token=hashed-token /g"
${RUN_COMMAND}
