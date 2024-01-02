#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
AWS_ACCOUNT_ID=$(grep "aws_account_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
DOCKER_CONFIG_JSON_PATH="${CLUSTER_PROFILE_DIR}/config.json"
CLUSTER_DATA_DIR="/tmp/clusters-data"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_ACCOUNT_ID
export OCM_TOKEN
export DOCKER_CONFIG=${CLUSTER_PROFILE_DIR}

RUN_COMMAND="poetry run python openshift_cli_installer/cli.py \
            --action create \
            --clusters-install-data-directory $CLUSTER_DATA_DIR \
            --ocm-token=$OCM_TOKEN \
            --s3-bucket-name=$S3_BUCKET_NAME "

CLUSTERS_CMD=""
NUM_CLUSTERS=0
for cluster_value in $(env | grep -E '^CLUSTER[0-9]+_CONFIG' | sort  --version-sort); do
    cluster_value=$(echo "$cluster_value" | sed -E  's/^CLUSTER[0-9]+_CONFIG=//')
    if  [ "${cluster_value}" ]; then
      CLUSTERS_CMD+=" --cluster ${cluster_value} "
      NUM_CLUSTERS=$(( NUM_CLUSTERS + 1))
    fi
done

if [ $NUM_CLUSTERS -eq 1 ]; then
  if [[ "$CLUSTERS_CMD" =~ .*"name=".* ]]; then
    echo "Using provided name"
  elif [ "${RANDOMIZE_CLUSTER_NAME}" = "true" ]; then
    subfix=$(openssl rand -hex 2)
    CLUSTER_NAME="$CLUSTER_NAME_PREFIX-$subfix"
    CLUSTERS_CMD=${CLUSTERS_CMD/cluster /cluster name=${CLUSTER_NAME};}
  else
    echo "Either pass cluster name or set 'RANDOMIZE_CLUSTER_NAME' to 'true'"
    exit 1
  fi
fi


RUN_COMMAND+="${CLUSTERS_CMD} "

if [ "${CLUSTERS_RUN_IN_PARALLEL}" = "true" ] && [ $NUM_CLUSTERS -gt 1 ]; then
    RUN_COMMAND+=" --parallel"
fi

if [[ -n "${S3_BUCKET_PATH}" ]]; then
    RUN_COMMAND+=" --s3-bucket-path=${S3_BUCKET_PATH} "
fi

if [[ -n "${PULL_SECRET_NAME}" ]]; then
    RUN_COMMAND+=" --registry-config-file=/var/run/secrets/ci.openshift.io/cluster-profile/${PULL_SECRET_NAME} --docker-config-file ${DOCKER_CONFIG_JSON_PATH}"
fi

if [[ -n "${GCP_SERVICE_ACCOUNT_NAME}" ]]; then
    RUN_COMMAND+=" --gcp-service-account-file=${CLUSTER_PROFILE_DIR}/${GCP_SERVICE_ACCOUNT_NAME} "
fi

if [ "${COLLECT_MUST_GATHER}" = "true" ]; then
  RUN_COMMAND+=" --must-gather-output-dir=${ARTIFACT_DIR} "
fi

echo "$RUN_COMMAND" | sed -r "s/ocm-token=[A-Za-z0-9\.\-]+/ocm-token=hashed-token /g"

set +e
${RUN_COMMAND}
return_code=$?

if [ $NUM_CLUSTERS -eq 1 ]; then
  CLUSTER_NAME=$(awk -F'.*name=|;' '{print $2}' <<< "$CLUSTERS_CMD")
  CLUSTER_PLATFORM=$(awk -F'.*platform=|;' '{print $2}' <<< "$CLUSTERS_CMD")
  CLUSTER_DATA_DIR="$CLUSTER_DATA_DIR/$CLUSTER_PLATFORM/$CLUSTER_NAME"
  CLUSTER_AUTH_DIR="$CLUSTER_DATA_DIR/auth"
  cp "$CLUSTER_AUTH_DIR/kubeconfig" "${SHARED_DIR}/kubeconfig"
  cp "$CLUSTER_AUTH_DIR/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
  grep 'display-name' "$CLUSTER_DATA_DIR/cluster_data.yaml" | awk -F': ' '{print $2}' > "${SHARED_DIR}/cluster-name"
  grep 'api-url' "$CLUSTER_DATA_DIR/cluster_data.yaml" |  awk -F': ' '{print $2}' > "${SHARED_DIR}/api.url"
  grep 'console-url' "$CLUSTER_DATA_DIR/cluster_data.yaml" |  awk -F': ' '{print $2}' > "${SHARED_DIR}/console.url"
  grep 'cluster-id' "$CLUSTER_DATA_DIR/cluster_data.yaml" |  awk -F': ' '{print $2}' > "${SHARED_DIR}/cluster-id"
fi

# Save cluster_data.yaml and kubeconfig files to be used during cluster deletion
# find $CLUSTER_DATA_DIR  -name "cluster_data.yaml"  | tar -zcvf "${SHARED_DIR}/clusters_data.tar.gz" -T -
tar -zcvf "${SHARED_DIR}/clusters_data.tar.gz" --exclude=*.json --exclude=*terraform* --exclude=*.zip --exclude=*.tf* --exclude=tls --exclude=*.log  -C $CLUSTER_DATA_DIR .

set -e
exit "$return_code"
