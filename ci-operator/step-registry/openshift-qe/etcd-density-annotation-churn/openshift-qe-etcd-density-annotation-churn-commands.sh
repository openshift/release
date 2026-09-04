#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
# Do not enable `set -x`: these scripts read and export Elasticsearch
# credentials (ES_USERNAME/ES_PASSWORD) and construct an authenticated
# ES_SERVER URL; tracing would leak them into the CI logs.
oc projects
oc version
pushd /tmp

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}
ES_HOST="search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
UUID=$(uuidgen)

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags "${REPO_URL}.git" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)"
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export WORKLOAD="etcd-density annotation-churn"
# Patch the indexing call in run.sh so the fingerprint records "annotation-churn"
sed -i '/index\.sh/s|WORKLOAD="$WORKLOAD"|WORKLOAD="annotation-churn"|' run.sh

# Variant-specific flags
EXTRA_FLAGS="--iterations=${ITERATIONS} --patch-replicas=${PATCH_REPLICAS} --patch-rounds=${PATCH_ROUNDS}"
# Flags not handled by run.sh
EXTRA_FLAGS+=" --gc-metrics=${GC_METRICS} --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --metrics-profile=${METRICS_PROFILES}"
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
if [[ -n "${USER_METADATA}" ]]; then
    echo "${USER_METADATA}" > user-metadata.yaml
    EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
EXTRA_FLAGS+=" ${KB_FLAGS}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
export EXTRA_FLAGS UUID ADDITIONAL_PARAMS

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -d ${METRICS_FOLDER} ]]; then
    cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
fi

exit ${RUN_EXIT_CODE}
