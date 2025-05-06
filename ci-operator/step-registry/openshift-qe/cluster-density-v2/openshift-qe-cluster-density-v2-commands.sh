#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

#Support Libvirt Hypershift Cluster
cluster_infra=$(oc get  infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
hypershift_pods=$(! oc -n hypershift get pods| grep operator >/dev/null ||oc -n hypershift get pods| grep operator |wc -l)
if [[ $cluster_infra == "BareMetal" && $hypershift_pods -ge 1 ]];then
        echo "Executing cluster-density-v2 in hypershift cluster"
        if [[ -f $SHARED_DIR/proxy-conf.sh ]];then
                echo "Set http proxy for hypershift cluster"
                . $SHARED_DIR/proxy-conf.sh
        fi
        echo "Configure KUBECONFIG for hosted cluster and execute kube-buner in it"
        export KUBECONFIG=$SHARED_DIR/nested_kubeconfig
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=cluster-density-v2

current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)

# Run a non-indexed warmup for scheduling inconsistencies
ES_SERVER="" ITERATIONS=${current_worker_count} CHURN=false EXTRA_FLAGS='--pod-ready-threshold=2m' ./run.sh

# The measurable run
iteration_multiplier=$(($ITERATION_MULTIPLIER_ENV))
export ITERATIONS=$(($iteration_multiplier*$current_worker_count))

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE}"

if [[ -n "${USER_METADATA}" ]]; then
    USER_METADATA=$(echo "$USER_METADATA" | xargs)
    IFS=',' read -r -a env_array <<< "$USER_METADATA"
    true > user-metadata.yaml
    for env_pair in "${env_array[@]}"; do
      env_pair=$(echo "$env_pair" | xargs)
      env_key=$(echo "$env_pair" | cut -d'=' -f1)
      env_value=$(echo "$env_pair" | cut -d'=' -f2-)
      echo "$env_key: \"$env_value\"" >> user-metadata.yaml
    done
    EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
export EXTRA_FLAGS
export ADDITIONAL_PARAMS

rm -f ${SHARED_DIR}/index.json
./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $ITERATIONS" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json

cp "${SHARED_DIR}"/index_data.json "${SHARED_DIR}"/${WORKLOAD}-index_data.json 
cp "${SHARED_DIR}"/${WORKLOAD}-index_data.json  "${ARTIFACT_DIR}"/${WORKLOAD}-index_data.json


if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
