#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x


# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi


ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

# Clone the e2e repo
if [[ "${E2E_VERSION}" != "default" ]]; then
    git clone "https://github.com/cloud-bulldozer/e2e-benchmarking" /tmp/e2e-benchmarking --branch "${E2E_VERSION}" --depth 1
    pushd /tmp/e2e-benchmarking/workloads/ingress-perf
else
    pushd /e2e-benchmarking/workloads/ingress-perf
fi

# ES Configuration
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ES_INDEX="ingress-performance"

# Start the Workload
./run.sh
