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

# Download the latest ACK file
if [ ${JUNIT} == true ]; then
  curl -sL https://raw.githubusercontent.com/cloud-bulldozer/orion/refs/heads/main/ack/${VERSION}_${ACK_FILE} > /tmp/${VERSION}_${ACK_FILE}
fi

if [[ ${ES_TYPE} == "qe" ]]; then
    ES_PASSWORD=$(cat "/secret/qe/password")
    ES_USERNAME=$(cat "/secret/qe/username")
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
else
    ES_PASSWORD=$(cat "/secret/internal/password")
    ES_USERNAME=$(cat "/secret/internal/username")
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@opensearch.app.intlab.redhat.com"
fi

pip install .
export EXTRA_FLAGS=" --lookback ${LOOKBACK}d"
if [[ ! -z "$UUID" ]]; then
    export EXTRA_FLAGS+=" --uuid ${UUID}"
fi
if [ ${HUNTER_ANALYZE} == "true" ]; then
    export EXTRA_FLAGS+=" --hunter-analyze"
fi
if [ ${JUNIT} == true ]; then
    export EXTRA_FLAGS+=" --output-format junit"
    export EXTRA_FLAGS+=" --save-output-path=junit.xml"
fi

if [[ ! -z "$ORION_CONFIG" ]]; then
    export CONFIG="${ORION_CONFIG}"
fi

if [[ ! -z "$ACK_FILE" ]]; then
    export EXTRA_FLAGS+=" --ack /tmp/${VERSION}_${ACK_FILE}"
fi

if [[ -n "${ORION_ENVS:-}" ]]; then
    ORION_ENVS=$(echo "$ORION_ENVS" | xargs)
    IFS=',' read -r -a env_array <<< "$ORION_ENVS"
    for env_pair in "${env_array[@]}"; do
      env_pair=$(echo "$env_pair" | xargs)
      env_key=$(echo "$env_pair" | cut -d'=' -f1)
      env_value=$(echo "$env_pair" | cut -d'=' -f2-)
      export "$env_key"="$env_value"
    done
fi

if [[ -n "${LOOKBACK_SIZE:-}" ]]; then
    export EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

set +e
es_metadata_index=${ES_METADATA_INDEX} es_benchmark_index=${ES_BENCHMARK_INDEX} VERSION=${VERSION} orion cmd --config ${CONFIG} ${EXTRA_FLAGS}
orion_exit_status=$?
set -e

if [ ${JUNIT} == true ]; then
  cp *.xml ${ARTIFACT_DIR}/
else
  cat *.csv
fi

exit $orion_exit_status