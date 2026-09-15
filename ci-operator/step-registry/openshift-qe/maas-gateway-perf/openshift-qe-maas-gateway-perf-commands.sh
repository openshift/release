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
pushd /tmp

UUID=$(uuidgen)
ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

# Clone e2e-benchmarking
REPO_URL="https://github.com/vishnuchalla/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags "${REPO_URL}.git" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)"
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/maas-gateway-perf

# Set environment variables
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
export UUID
export OPERATOR_TYPE="${OPERATOR_TYPE}"
export PROVIDERS="${PROVIDERS}"
export PAYLOAD_SIZES="${PAYLOAD_SIZES}"
export CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS}"
export BENCHMARK_DURATION="${BENCHMARK_DURATION}"
export WARMUP="${WARMUP}"
export KUBE_BURNER_VERSION="${KUBE_BURNER_VERSION}"
export MAAS_REF="${MAAS_REF}"
export DEPLOY_EXTRA_ARGS="${DEPLOY_EXTRA_ARGS}"
export EXTRA_FLAGS="${EXTRA_FLAGS}"
export ARTIFACT_DIR="${ARTIFACT_DIR}"

# Run the benchmark
set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

# Copy any remaining artifacts
METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -d ${METRICS_FOLDER} ]]; then
  cp -r ${METRICS_FOLDER} "${ARTIFACT_DIR}/"
fi

if [[ -d /tmp/maas-benchmark-results ]]; then
  cp -r /tmp/maas-benchmark-results "${ARTIFACT_DIR}/" 2>/dev/null || true
fi

# Handle timeout exit code
if [[ "${RUN_EXIT_CODE}" -eq 2 ]]; then
  echo "kube-burner returned exit code 2 (timeout)"
  echo "Checking cluster health before exiting"
  if /tmp/kube-burner-ocp cluster-health; then
    echo "Cluster is still healthy. Ignoring workload timeout"
    oc delete ns maas-perf-test --ignore-not-found || true
    exit 0
  fi
fi

exit ${RUN_EXIT_CODE}
