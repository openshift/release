#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc config view
oc projects
pushd /tmp

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret/es}
WINDOWS_SECRETS_PATH=${WINDOWS_SECRETS_PATH:-/secret/perfci}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

WINDOWS_IMAGE_URL=${WINDOWS_IMAGE_URL:-$(cat "${WINDOWS_SECRETS_PATH}/windows_url" 2>/dev/null || echo "")}
if [[ -z "${WINDOWS_IMAGE_URL}" ]]; then
    echo "ERROR: WINDOWS_IMAGE_URL is not set and windows_url not found in ${WINDOWS_SECRETS_PATH}"
    exit 1
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)"
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export WORKLOAD=windows-bootstorm
export KUBE_BURNER_VERSION="${KUBE_BURNER_VERSION}"

EXTRA_FLAGS="${BOOTSTORM_EXTRA_FLAGS} --windows-image-url=${WINDOWS_IMAGE_URL} --vms-per-node=${VMS_PER_NODE} --storage-class=${STORAGE_CLASS} --access-mode=${ACCESS_MODE} --eviction-strategy=${EVICTION_STRATEGY} --profile-type=${PROFILE_TYPE}"

if [[ "${PER_NODE_DV}" == "true" ]]; then
    EXTRA_FLAGS+=" --per-node-dv"
fi

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export EXTRA_FLAGS

./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    if [[ -n "${metrics_folder_name}" ]]; then
        cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
    fi
fi
