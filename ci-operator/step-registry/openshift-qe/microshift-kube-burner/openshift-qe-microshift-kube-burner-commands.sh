#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# MicroShift kubeconfig produced by openshift-qe-microshift-deploy
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# MicroShift has no Project API and no config.openshift.io: do NOT use
# `oc projects` or `oc get infrastructure cluster` here. Sanity check instead:
oc get nodes -o wide
oc get node -l node-role.kubernetes.io/worker -o name | grep -q . \
  || { echo "ERROR: no worker-labeled node; kube-burner selector will match nothing"; exit 1; }

UUID=$(uuidgen)

# Tell the e2e-benchmarking indexer (utils/index.sh) to take its
# MicroShift-safe metadata path instead of the OpenShift config APIs.
export PLATFORM=microshift

# Elasticsearch (same perfscale ES as the OCP steps)
# Disable tracing while assembling credentials
set +x
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
ES_HOST="search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
export ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"
set -x

# Prometheus handoff: env override > SHARED_DIR file > none (degraded run)
PROM_URL="${MICROSHIFT_PROMETHEUS_URL}"
if [[ -z "${PROM_URL}" && -f "${SHARED_DIR}/prometheus_url" ]]; then
  PROM_URL=$(cat "${SHARED_DIR}/prometheus_url")
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name')
TAG_OPTION="--branch $(if [ "${E2E_VERSION}" == "default" ]; then echo "${LATEST_TAG}"; else echo "${E2E_VERSION}"; fi)"
pushd /tmp
git clone ${REPO_URL} ${TAG_OPTION} --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

# MicroShift-specific flags (see e2e-benchmarking kube-burner-ocp-wrapper README)
EXTRA_FLAGS="--metrics-profile=microshift-metrics.yml --alerting=false --local-indexing"
if [[ -n "${PROM_URL}" ]]; then
  EXTRA_FLAGS+=" --prometheus-url=${PROM_URL}"
else
  # Without Prometheus, disable metrics collection entirely: on MicroShift,
  # kube-burner-ocp exits fatally if metrics are enabled with no endpoint.
  echo "WARNING: no prometheus_url; running without metrics/indexing"
  export ES_SERVER=""
  EXTRA_FLAGS="--alerting=false"
fi

case "${WORKLOAD}" in
  node-density)
    EXTRA_FLAGS+=" --pods-per-node=${PODS_PER_NODE} --pod-ready-threshold=${POD_READY_THRESHOLD}"
    ;;
  node-density-cni)
    EXTRA_FLAGS+=" --pods-per-node=${PODS_PER_NODE}"
    ;;
  network-policy)
    export ITERATIONS   # run.sh requires it for this workload
    ;;
  *)
    echo "ERROR: unsupported WORKLOAD=${WORKLOAD}"; exit 1
    ;;
esac
EXTRA_FLAGS+=" ${EXTRA_FLAGS_APPEND}"

export WORKLOAD QPS BURST="${BURST:-${QPS}}" UUID EXTRA_FLAGS
if [[ "${KUBE_BURNER_VERSION}" != "default" ]]; then
  export KUBE_BURNER_VERSION
fi

./run.sh

# Artifacts
if compgen -G "collected-metrics-${UUID}/*" > /dev/null; then
  cp -r "collected-metrics-${UUID}" "${ARTIFACT_DIR}/"
fi
