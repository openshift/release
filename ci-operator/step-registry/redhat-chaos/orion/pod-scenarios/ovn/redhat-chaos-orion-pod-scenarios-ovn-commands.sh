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


# set enviornment based variables if they exist
if [ -f "${KUBECONFIG}" ]; then
    masters=0
    infra=0
    workers=0
    all=0
    master_type=""
    infra_type=""
    worker_type=""

    # Using from e2e-benchmarking
    for node in $(oc get nodes --ignore-not-found --no-headers -o custom-columns=:.metadata.name || true); do
        labels=$(oc get node "$node" --no-headers -o jsonpath='{.metadata.labels}')
        if [[ $labels == *"node-role.kubernetes.io/master"* ]]; then
            masters=$((masters + 1))
            master_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
            taints=$(oc get node "$node" -o jsonpath='{.spec.taints}')

            if [[ $labels == *"node-role.kubernetes.io/worker"* && $taints == "" ]]; then
                workers=$((workers + 1))
            fi
        elif [[ $labels == *"node-role.kubernetes.io/infra"* ]]; then
            infra=$((infra + 1))
            infra_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
        elif [[ $labels == *"node-role.kubernetes.io/worker"* ]]; then
            workers=$((workers + 1))
            worker_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
        fi
        all=$((all + 1))
    done
    export master_type
    export infra_type
    worker_count=$workers
    export worker_count

    master_count=$masters
    export master_count

    infra_count=$infra
    export infra_count

    total_node_count=$all
    export total_node_count
    node_instance_type=$worker_type
    export node_instance_type
    network_plugins=$(oc get network.config/cluster -o jsonpath='{.status.networkType}')
    export network_plugins
    cloud_infrastructure=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
    export cloud_infrastructure
    cluster_type=""
    if [ "$cloud_infrastructure" = "AWS" ]; then
        cluster_type=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.resourceTags[?(@.key=="red-hat-clustertype")].value}') || echo "Cluster Install Failed"
    fi
    if [ -z "$cluster_type" ]; then
        cluster_type="self-managed"
    fi
    cloud_type=$cluster_type
    export cloud_type
    export version=${VERSION:=$(oc version -o json | jq -r '.openshiftVersion')}
fi

env


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

if [[ -n "${DEBUG+x}" && ${DEBUG} == true ]]; then
    export EXTRA_FLAGS+=" --debug"
fi


cat $CONFIG
set +e
set -o pipefail
FILENAME=$(echo $CONFIG | awk -F/ '{print $2}' | awk -F. '{print $1}')
es_metadata_index=${ES_METADATA_INDEX} es_benchmark_index=${ES_BENCHMARK_INDEX} VERSION=${VERSION} jobtype="periodic" orion --node-count ${IGNORE_JOB_ITERATIONS} --config ${CONFIG} ${EXTRA_FLAGS} --debug | tee ${ARTIFACT_DIR}/$FILENAME.txt
orion_exit_status=$?
set -e

cp *.csv *.xml ${ARTIFACT_DIR}/

exit $orion_exit_status
