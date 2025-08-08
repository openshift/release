#!/bin/bash
set -x

if [ ${RUN_ORION} == false ]; then
  exit 0
fi

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

send_slack_notification() {
  local jobID="$1"

  SLACK_WEBHOOK_URL=$(cat /var/run/vault/mirror-registry/olm_slack_channel 2>/dev/null)
  export SLACK_WEBHOOK_URL

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "Error: SLACK_WEBHOOK_URL environment variable is required."
    return 1
  fi

  export PYTHONPATH="/go/src/github.com/openshift/openshift-tests-private/hack/:${PYTHONPATH:-}"

  python3 - <<EOF
from slack_notify import SlackClient
import os

webhook_url = os.getenv("SLACK_WEBHOOK_URL")
notificationList = [
    "*OLMv1 Performance Abnormal Notification* :zap:",
    "Prow Job: ${jobID}"
]

try:
    client = SlackClient()
    client.notify_to_slack(webhook_url, notificationList)
except Exception as e:
    print(f"Failed to send Slack notification: {e}")
    sys.exit(1)
EOF
}

notify_slack_if_failure() {
  local xml_file="$1"

  if [[ ! -f "$xml_file" ]]; then
    echo "Error: File $xml_file not found" >&2
    return 1
  fi

  local failures
  failures=$(sed -n 's/.*failures="\([0-9]*\)".*/\1/p' "$xml_file" | head -n1)

  echo "[DEBUG] Detected failures = '$failures'"

  if [[ -z "$failures" || ! "$failures" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Unable to parse failure count from XML." >&2
    return 1
  fi

  if [[ "$failures" != "0" ]]; then
    echo "Test failure detected, sending Slack notification..."

    local prow_base_url="https://qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/view/gs/qe-private-deck/logs"
    local prow_link="N/A"
    if [[ -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" ]]; then
      prow_link="${prow_base_url}/${JOB_NAME}/${BUILD_ID}"
    fi
    send_slack_notification "$prow_link"
    
  else
    echo "All tests passed. No Slack notification sent."
  fi
}

if [[ $TAG == "latest" ]]; then
    LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/orion/releases/latest" | jq -r '.tag_name');
else
    LATEST_TAG=$TAG
fi
git clone --branch $LATEST_TAG $ORION_REPO --depth 1
pushd orion

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
  *)
    ES_PASSWORD=$(<"/secret/internal/password")
    ES_USERNAME=$(<"/secret/internal/username")
    ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@opensearch.app.intlab.redhat.com"
    ;;
esac

export ES_SERVER

pip install .
export EXTRA_FLAGS=" --lookback ${LOOKBACK}d --hunter-analyze"

if [[ ! -z "$UUID" ]]; then
    export EXTRA_FLAGS+=" --uuid ${UUID}"
fi

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

if [[ ! -z "$ACK_FILE" ]]; then
    # Download the latest ACK file
    curl -sL https://raw.githubusercontent.com/cloud-bulldozer/orion/refs/heads/main/ack/${VERSION}_${ACK_FILE} > /tmp/${VERSION}_${ACK_FILE}
    export EXTRA_FLAGS+=" --ack /tmp/${VERSION}_${ACK_FILE}"
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
FILENAME=$(echo $CONFIG | awk -F/ '{print $2}' | awk -F. '{print $1}')
es_metadata_index=${ES_METADATA_INDEX} es_benchmark_index=${ES_BENCHMARK_INDEX} VERSION=${VERSION} orion cmd --config ${CONFIG} ${EXTRA_FLAGS} | tee ${ARTIFACT_DIR}/$FILENAME.txt
orion_exit_status=$?
set -e

if [ ${OUTPUT_FORMAT} == "JUNIT" ]; then
  cp *.csv *.xml ${ARTIFACT_DIR}/
fi

notify_slack_if_failure "junit_olmv1-GCP.xml"

exit $orion_exit_status
