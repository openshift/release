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

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

oc config view
oc projects

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=node-density-heavy


export CLEANUP_WHEN_FINISH=true

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export COMPARISON_CONFIG="clusterVersion.json podLatency.json containerMetrics.json kubelet.json etcd.json crio.json nodeMasters-max.json nodeWorkers.json"
export GEN_CSV=true
export EMAIL_ID_FOR_RESULTS_SHEET='ocp-perfscale-qe@redhat.com'

EXTRA_FLAGS="${NDH_EXTRA_FLAGS} --gc-metrics=false --pods-per-node=$PODS_PER_NODE --namespaced-iterations=$NAMESPACED_ITERATIONS --iterations-per-namespace=$ITERATIONS_PER_NAMESPACE --profile-type=${PROFILE_TYPE} --burst=${BURST} --qps=${QPS} --pprof=${PPROF} --pprof-interval=1m"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

if [[ -n "${USER_METADATA}" ]]; then
  echo "${USER_METADATA}" > user-metadata.yaml
  EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
export EXTRA_FLAGS
export ADDITIONAL_PARAMS

# Setup pprof secrets for kube-apiserver profiling
oc create ns benchmark-operator || true
set +x
oc create serviceaccount kube-burner -n benchmark-operator || true
oc create clusterrolebinding kube-burner-crb --clusterrole=cluster-admin --serviceaccount=benchmark-operator:kube-burner || true
BEARER_TOKEN=$(oc create token -n benchmark-operator kube-burner --duration=6h || oc sa get-token kube-burner -n benchmark-operator)
export BEARER_TOKEN
set -x

# Build kube-burner-ocp from fork with kube-apiserver pprof targets
FORK_REPO="https://github.com/redhat-chai-bot/kube-burner_kube-burner-ocp.git"
FORK_BRANCH="add-kube-apiserver-pprof-targets"
echo "Building kube-burner-ocp from ${FORK_REPO} branch ${FORK_BRANCH}..."
KB_OCP_SRC=$(mktemp -d)
curl -sL "https://github.com/redhat-chai-bot/kube-burner_kube-burner-ocp/archive/refs/heads/add-kube-apiserver-pprof-targets.tar.gz" -o /tmp/kb-ocp.tar.gz
tar -xzf /tmp/kb-ocp.tar.gz --strip-components=1 -C "$KB_OCP_SRC"
rm /tmp/kb-ocp.tar.gz
# Install Go (required for building kube-burner-ocp from source)
GO_VERSION="1.25.9"
curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
mkdir -p /tmp/goroot
tar -C /tmp/goroot -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
export GOROOT="/tmp/goroot/go"
export PATH="${GOROOT}/bin:${PATH}"
# Build (direct go build — make is not available in CI container)
cd "$KB_OCP_SRC"
mkdir -p bin/amd64
GOARCH=amd64 CGO_ENABLED=0 go build -v -ldflags "-X github.com/cloud-bulldozer/go-commons/v2/version.Version=test" -o bin/amd64/kube-burner-ocp ./cmd/
cd -
mkdir -p /tmp/kube-burner-ocp-bin
cp "${KB_OCP_SRC}/bin/amd64/kube-burner-ocp" /tmp/kube-burner-ocp-bin/kube-burner-ocp
rm -rf "${KB_OCP_SRC}"
tar czf /tmp/kube-burner-ocp-custom.tar.gz -C /tmp/kube-burner-ocp-bin kube-burner-ocp
export KUBE_BURNER_URL="file:///tmp/kube-burner-ocp-custom.tar.gz"
set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

#node-density-heavy test
if [[ ${PPROF} == "true" ]]; then
  cp -r pprof-data "${ARTIFACT_DIR}/"
fi

exit ${RUN_EXIT_CODE}
