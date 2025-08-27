#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
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

# Managment Kubeconfig for ROSA-HCP
# Set this variable only for HCP clusters on AWS
CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ ${CONTROL_PLANE_TOPOLOGY} == "External" && $cluster_infra == "AWS" ]]; then
    if [[ -f "${SHARED_DIR}/hs-mc.kubeconfig" ]]; then
        # Check if the cluster is accessible from prow environment, 
        # Set this variable only if accessible
        MC_CLUSTER_INFRA=$(oc --kubeconfig="${SHARED_DIR}/hs-mc.kubeconfig" get  infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
        if [[ $MC_CLUSTER_INFRA == "AWS" ]]; then
            export MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
            export ES_INDEX=ripsaw-kube-burner
        fi
    fi
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=node-density

RANDOM_WORKER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n1)
oc adm must-gather --timeout=3h --dest-dir "${ARTIFACT_DIR}/" -- PROFILING_NODE_SECONDS=60 gather_profiling_node $RANDOM_WORKER_NODE &

# A non-indexed warmup run
ES_SERVER="" EXTRA_FLAGS="--pods-per-node=50 --pod-ready-threshold=60s" ./run.sh

# The measurable run
EXTRA_FLAGS="--gc-metrics=true --pods-per-node=$PODS_PER_NODE --pod-ready-threshold=$POD_READY_THRESHOLD --profile-type=${PROFILE_TYPE}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export EXTRA_FLAGS

rm -f ${SHARED_DIR}/index.json

RANDOM_WORKER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n1)

gather_loop() {
  local count=1
  while true; do
    echo "Starting background must-gather iteration #$count..."
    timestamp=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
    gather_dir="${ARTIFACT_DIR}/node-profile-${timestamp}"
    # Start must-gather in background and let it run independently
    oc adm must-gather --dest-dir "$gather_dir" -- gather_profiling_node "$RANDOM_WORKER_NODE" &
    count=$((count + 1))
    sleep 60
  done
}

# Run the gather loop in background
gather_loop &
GATHER_LOOP_PID=$!

# Run workload immediately
./run.sh

# After workload finishes, kill background gather loop
echo "Workload finished. Stopping gather loop (PID $GATHER_LOOP_PID)..."
kill "$GATHER_LOOP_PID" 2>/dev/null || true
wait "$GATHER_LOOP_PID" 2>/dev/null || true
echo "Gather loop stopped."

folder_name=$(ls -t -d /tmp/*/ | head -1)
jq ".iterations = $PODS_PER_NODE" $folder_name/index_data.json >> ${SHARED_DIR}/index_data.json

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
