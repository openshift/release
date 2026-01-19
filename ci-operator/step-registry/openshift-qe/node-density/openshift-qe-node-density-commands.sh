#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

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

EXTRA_FLAGS="--gc-metrics=true --pods-per-node=$PODS_PER_NODE --pod-ready-threshold=$POD_READY_THRESHOLD --profile-type=${PROFILE_TYPE} --pprof=${PPROF}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export EXTRA_FLAGS


# Run workload immediately
./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
if [[ ${PPROF} == "true" ]]; then
  cp -r pprof-data "${ARTIFACT_DIR}/"
fi
