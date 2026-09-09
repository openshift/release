#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
pushd /tmp

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

UUID=$(uuidgen)

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

git clone https://github.com/kube-burner/kube-burner-ocp --depth 1 /tmp/kube-burner-ocp-repo
cp /tmp/kube-burner-ocp-repo/cmd/config/batch-churn/*.yml .
cp /tmp/kube-burner-ocp-repo/cmd/config/scripts/chaos.sh .
chmod +x chaos.sh
export PATH="${PWD}:${PATH}"
BATCH_CHURN_CONFIG="config.yml"

export WORKLOAD=init
# Patch the indexing call in run.sh so the fingerprint records "batch-churn"
sed -i '/index\.sh/s|WORKLOAD="$WORKLOAD"|WORKLOAD="batch-churn"|' run.sh

EXTRA_FLAGS="-c ${BATCH_CHURN_CONFIG}"
EXTRA_FLAGS+=" --iterations=${ITERATIONS}"
EXTRA_FLAGS+=" --churn-cycles=${CHURN_CYCLES}"
EXTRA_FLAGS+=" --churn-percent=${CHURN_PERCENT}"
EXTRA_FLAGS+=" --churn-duration=${CHURN_DURATION}"
EXTRA_FLAGS+=" --gc-metrics=${GC_METRICS} --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --metrics-profile=${METRICS_PROFILES}"
EXTRA_FLAGS+=" --set DEPLOYMENT_COUNT=${DEPLOYMENT_COUNT}"
EXTRA_FLAGS+=" --set UNIQUE_SECRETS=${UNIQUE_SECRETS} --set UNIQUE_CMS=${UNIQUE_CMS}"
EXTRA_FLAGS+=" --set UNIQUE_KV=${UNIQUE_KV} --set UNIQUE_KV_LEN=${UNIQUE_KV_LEN}"
EXTRA_FLAGS+=" --set UNIQUE_LARGE_SECRETS=${UNIQUE_LARGE_SECRETS} --set UNIQUE_LARGE_SECRET_SIZE=${UNIQUE_LARGE_SECRET_SIZE}"
EXTRA_FLAGS+=" --set UNIQUE_LARGE_CMS=${UNIQUE_LARGE_CMS} --set UNIQUE_LARGE_CM_SIZE=${UNIQUE_LARGE_CM_SIZE}"
EXTRA_FLAGS+=" --set COMMON_SECRETS=${COMMON_SECRETS} --set COMMON_SECRET_FILES=${COMMON_SECRET_FILES} --set COMMON_SECRET_FILE_SIZE=${COMMON_SECRET_FILE_SIZE}"
EXTRA_FLAGS+=" --set COMMON_CMS=${COMMON_CMS} --set COMMON_CM_SIZE=${COMMON_CM_SIZE}"

if [[ -n "${CHAOS_ACTION}" ]]; then
  EXTRA_FLAGS+=" --set CHAOS_ACTION=${CHAOS_ACTION} --set CHAOS_DELAY=${CHAOS_DELAY} --set CHAOS_CYCLES=${CHAOS_CYCLES_COUNT}"
fi

EXTRA_FLAGS+=" --timeout=12h"
EXTRA_FLAGS+=" ${KB_FLAGS}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ -n "${USER_METADATA}" ]]; then
  echo "${USER_METADATA}" > user-metadata.yaml
  EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi

export EXTRA_FLAGS UUID

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -d ${METRICS_FOLDER} ]]; then
  cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
fi

if [[ "${RUN_EXIT_CODE}" -eq 2 ]]; then
  echo "kube-burner returned exit code 2, which means the workload reached a timeout"
  echo "Checking cluster health before exiting"
  if /tmp/kube-burner-ocp cluster-health; then
    echo "Cluster is still healthy. Ignoring workload timeout to run remaining workloads"
    echo "Deleting any left-over test resources"
    oc delete ns -l kube-burner.io/uuid
    exit 0
  fi
fi

exit ${RUN_EXIT_CODE}
