#!/bin/bash
set -x

if [ ${RUN_ORION} == false ]; then
  exit 0
fi

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

if [[ $TAG == "latest" ]]; then
    LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/orion/releases/latest" | jq -r '.tag_name');
else
    LATEST_TAG=$TAG
fi
git clone --branch $LATEST_TAG $ORION_REPO --depth 1
pushd orion

pip install -r requirements.txt

OPENSEARCH_PASSWORD=$(<"/secret/telco5g/password")
OPENSEARCH_USERNAME=$(<"/secret/telco5g/username")
OPENSEARCH_HOST=$(<"/secret/telco5g/hostname")
ES_SERVER="https://${OPENSEARCH_USERNAME}:${OPENSEARCH_PASSWORD}@${OPENSEARCH_HOST}"

pip install .
export EXTRA_FLAGS=" --hunter-analyze"

if [ ${OUTPUT_FORMAT} == "JUNIT" ]; then
    export EXTRA_FLAGS+=" --output-format junit"
    export EXTRA_FLAGS+=" --save-output-path=junit.xml"
elif [ "${OUTPUT_FORMAT}" == "JSON" ]; then
    export EXTRA_FLAGS+=" --output-format json"
elif [ "${OUTPUT_FORMAT}" == "TEXT" ]; then
    export EXTRA_FLAGS+=" --output-format text"
else
    echo "Unsupported format: ${OUTPUT_FORMAT}"
    exit 1
fi

if [[ -n "$ORION_CONFIG" ]]; then
    if [[ "$ORION_CONFIG" =~ ^https?:// ]]; then
        fileBasename="${ORION_CONFIG##*/}"
        if curl -fsSL "$ORION_CONFIG" -o "$ARTIFACT_DIR/$fileBasename"; then
            export CONFIG="$ARTIFACT_DIR/$fileBasename"
        else
            echo "Error: Failed to download $ORION_CONFIG" >&2
            exit 1
        fi
    else
        export CONFIG="$ORION_CONFIG"
    fi
fi


if [ ${COLLAPSE} == "true" ]; then
    export EXTRA_FLAGS+=" --collapse"
fi

if [[ -n "${ORION_ENVS}" ]]; then
    ORION_ENVS=$(echo "$ORION_ENVS" | xargs)
    IFS=',' read -r -a env_array <<< "$ORION_ENVS"
    for env_pair in "${env_array[@]}"; do
      env_pair=$(echo "$env_pair" | xargs)
      env_key=$(echo "$env_pair" | cut -d'=' -f1)
      env_value=$(echo "$env_pair" | cut -d'=' -f2-)
      export "$env_key"="$env_value"
    done
fi

if [[ -n "${LOOKBACK_SIZE}" ]]; then
    export EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

set +e
set -o pipefail
echo "Start orion test"
FILENAME=$(echo $CONFIG | awk -F/ '{print $2}' | awk -F. '{print $1}')
ES_IDX=${ES_METADATA_INDEX} ES_SERVER=${ES_SERVER} orion cmd --config ${CONFIG} ${EXTRA_FLAGS} | tee ${ARTIFACT_DIR}/$FILENAME.txt
orion_exit_status=$?
set -e

if [ ${OUTPUT_FORMAT} == "JUNIT" ]; then
  cp *.csv *.xml ${ARTIFACT_DIR}/
fi

exit $orion_exit_status
