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

# Invoked from orion repo by the openshift-ci bot
if [[ -n "${PULL_NUMBER-}" ]] && [[ "${REPO_NAME}" == "orion" ]]; then
  echo "Invoked from orion repo by the openshift-ci bot, switching to PR#${PULL_NUMBER}"
  git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
  git switch ${PULL_NUMBER}
fi

pip install -r requirements.txt

case "$ES_TYPE" in
  qe)
    ES_PASSWORD=$(<"/secret/qe/password")
    ES_USERNAME=$(<"/secret/qe/username")
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    ;;
  quay-qe)
    ES_PASSWORD=$(<"/secret/quay-qe/password")
    ES_USERNAME=$(<"/secret/quay-qe/username")
    ES_HOST=$(<"/secret/quay-qe/hostname")
    ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"
    ;;
  stackrox)
    ES_SECRETS_PATH='/secret_stackrox'
    ES_PASSWORD=$(<"${ES_SECRETS_PATH}/password")
    ES_USERNAME=$(<"${ES_SECRETS_PATH}/username")
    if [ -e "${ES_SECRETS_PATH}/host" ]; then
        ES_HOST=$(<"${ES_SECRETS_PATH}/host")
    fi
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
    ;;
  *)
    ES_PASSWORD=$(<"/secret/internal/password")
    ES_USERNAME=$(<"/secret/internal/username")
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@opensearch.app.intlab.redhat.com"
    ;;
esac

export ES_SERVER

pip install .
EXTRA_FLAGS=" --lookback ${LOOKBACK}d --hunter-analyze"

if [[ ! -z "$UUID" ]]; then
    EXTRA_FLAGS+=" --uuid ${UUID}"
fi

if [ ${OUTPUT_FORMAT} == "JUNIT" ]; then
    EXTRA_FLAGS+=" --output-format junit --save-output-path=junit.xml"
elif [ "${OUTPUT_FORMAT}" == "JSON" ]; then
    EXTRA_FLAGS+=" --output-format json"
elif [ "${OUTPUT_FORMAT}" == "TEXT" ]; then
    EXTRA_FLAGS+=" --output-format text"
else
    echo "Unsupported format: ${OUTPUT_FORMAT}"
    exit 1
fi

if [[ -n "$ORION_CONFIG" ]]; then
    if [[ "$ORION_CONFIG" =~ ^https?:// ]]; then
        fileBasename="${ORION_CONFIG##*/}"
        if curl -fsSL "$ORION_CONFIG" -o "$ARTIFACT_DIR/$fileBasename"; then
            CONFIG="$ARTIFACT_DIR/$fileBasename"
        else
            echo "Error: Failed to download $ORION_CONFIG" >&2
            exit 1
        fi
    else
        CONFIG="$ORION_CONFIG"
    fi
fi

if [[ -n "$ACK_FILE" ]]; then
    if [[ "$ACK_FILE" =~ ^https?:// ]]; then
        fileBasename="${ACK_FILE##*/}"
        ackFilePath="$ARTIFACT_DIR/$fileBasename"
        if ! curl -fsSL "$ACK_FILE" -o "$ackFilePath" ; then
            echo "Error: Failed to download $ACK_FILE" >&2
            exit 1
        fi
    else
        # Download the latest ACK file
        ackFilePath="$ARTIFACT_DIR/$ACK_FILE"
        curl -sL https://raw.githubusercontent.com/cloud-bulldozer/orion/refs/heads/main/ack/${VERSION}_${ACK_FILE} -o "$ackFilePath"
    fi
    EXTRA_FLAGS+=" --ack $ackFilePath"
fi

if [ ${COLLAPSE} == "true" ]; then
    EXTRA_FLAGS+=" --collapse"
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
    EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

if [[ -n "${LOOKBACK_SIZE}" ]]; then
    EXTRA_FLAGS+=" --lookback-size ${LOOKBACK_SIZE}"
fi

if [[ -n "${DISPLAY}" ]]; then
    EXTRA_FLAGS+=" --display ${DISPLAY}"
fi

set +e
set -o pipefail
FILENAME=$(echo $CONFIG | awk -F/ '{print $2}' | awk -F. '{print $1}')
es_metadata_index=${ES_METADATA_INDEX} es_benchmark_index=${ES_BENCHMARK_INDEX} VERSION=${VERSION} jobtype="periodic" orion --node-count ${IGNORE_JOB_ITERATIONS} --config ${CONFIG} ${EXTRA_FLAGS} | tee ${ARTIFACT_DIR}/$FILENAME.txt
orion_exit_status=$?
set -e

cp *.csv *.xml *.json *.txt "${ARTIFACT_DIR}/" 2>/dev/null || true

if [ $orion_exit_status -eq 3 ]; then
  echo "Orion returned exit code 3, which means there are no results to analyze."
  echo "Exiting zero since there were no regressions found."
  exit 0
fi

exit $orion_exit_status
