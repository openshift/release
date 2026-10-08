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
  # Disable xtrace: proxy-conf.sh may export HTTP_PROXY with embedded credentials.
  set +x
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

pushd /tmp

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

# Clone the e2e repo
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/ingress-perf

# ES Configuration
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ES_INDEX="ingress-performance"

# For environments where the Prometheus route is not reachable from the Prow runner
# (e.g. Bare Metal / Equinix where cluster ingress IPs are on private subnets),
# port-forward the prometheus-k8s service and set PROMETHEUS_URL / PROMETHEUS_TOKEN
# so ingress-perf uses the tunnel instead of the route.
PROM_HOST=$(oc get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "${PROM_HOST}" ]]; then
  if ! curl -ks --connect-timeout 5 "https://${PROM_HOST}/api/v1/status/runtimeinfo" > /dev/null 2>&1; then
    echo "Prometheus route ${PROM_HOST} unreachable — using port-forward tunnel"
    oc port-forward svc/prometheus-k8s 9090:9091 -n openshift-monitoring &
    PF_PID=$!
    # Wait for the tunnel to be ready
    for i in $(seq 1 10); do
      if curl -kso /dev/null "https://localhost:9090/-/ready" 2>/dev/null; then
        echo "Port-forward ready after ${i}s"
        break
      fi
      sleep 2
    done
    export PROMETHEUS_URL="https://localhost:9090"
    # Disable xtrace to avoid leaking the bearer token in build logs
    set +x
    PROMETHEUS_TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=2h)
    export PROMETHEUS_TOKEN
    set -x
    # shellcheck disable=SC2064
    trap "kill ${PF_PID} 2>/dev/null || true" EXIT

    # Use v0.6.1 which includes PROMETHEUS_URL/PROMETHEUS_TOKEN env var support
    # (cloud-bulldozer/ingress-perf#89)
    export INGRESS_PERF_VERSION="0.6.1"

    # BM clusters have no infra nodes — remove infra nodePlacement from tuningPatch
    # and reduce replicas to 1 so the ingress controller scales successfully.
    CONFIG_FILE="${CONFIG:-config/standard.yml}"
    sed -i 's|tuningPatch:.*|tuningPatch: '"'"'{"spec":{"replicas": 1}}'"'"'|g' "${CONFIG_FILE}"
    echo "BM: patched ${CONFIG_FILE} — removed infra nodePlacement, set replicas=1"
  fi
fi

# Start the Workload
./run.sh
