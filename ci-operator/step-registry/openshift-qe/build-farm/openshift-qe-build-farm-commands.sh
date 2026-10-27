#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if [[ "${CUSTOM_KB_BUILD:-}" == "true" ]]; then
  # Create bearer token for KAS pprof
  oc create namespace benchmark-operator --dry-run=client -o yaml | oc apply -f -
  oc create serviceaccount kube-burner -n benchmark-operator --dry-run=client -o yaml | oc apply -f -
  oc adm policy add-cluster-role-to-user cluster-admin -z kube-burner -n benchmark-operator
  export BEARER_TOKEN=$(oc create token kube-burner -n benchmark-operator --duration=12h)
  export PPROF=true

  # Install Go
  GO_VERSION="1.25.9"
  curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
  mkdir -p /tmp/goroot
  tar -C /tmp/goroot -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
  export GOROOT=/tmp/goroot/go
  export PATH="/tmp/goroot/go/bin:${PATH}"
  go version

  # Build custom kube-burner-ocp from fork with KAS pprof targets
  FORK_REPO="https://github.com/redhat-chai-bot/kube-burner_kube-burner-ocp"
  FORK_BRANCH="add-kube-apiserver-pprof-targets"
  KB_OCP_SRC=$(mktemp -d)
  echo "Building kube-burner-ocp from ${FORK_REPO} branch ${FORK_BRANCH}..."
  curl -sL "${FORK_REPO}/archive/refs/heads/${FORK_BRANCH}.tar.gz" -o /tmp/kb-ocp.tar.gz
  tar -xzf /tmp/kb-ocp.tar.gz --strip-components=1 -C "$KB_OCP_SRC"
  rm /tmp/kb-ocp.tar.gz
  cd "$KB_OCP_SRC"
  mkdir -p bin/amd64
  GOARCH=amd64 CGO_ENABLED=0 go build -v -ldflags \
    "-X github.com/cloud-bulldozer/go-commons/v2/version.Version=test" \
    -o bin/amd64/kube-burner-ocp ./cmd/
  echo "BUILD SUCCESS: $(ls -la bin/amd64/kube-burner-ocp)"
  cd -

  # Create tarball and override KUBE_BURNER_URL
  KB_TARBALL="/tmp/kube-burner-ocp-custom.tar.gz"
  tar -czf "$KB_TARBALL" -C "$KB_OCP_SRC/bin/amd64" kube-burner-ocp
  export KUBE_BURNER_URL="file://${KB_TARBALL}"
fi

cat /etc/os-release
oc config view
oc projects
oc version
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

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=build-farm

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+="${BUILD_FARM_EXTRA_FLAGS} --gc-metrics=false --profile-type=${PROFILE_TYPE}"

if [[ -n "${USER_METADATA}" ]]; then
  echo "${USER_METADATA}" > user-metadata.yaml
  EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
export EXTRA_FLAGS
export ADDITIONAL_PARAMS

./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

if [[ "${CUSTOM_KB_BUILD:-}" == "true" ]]; then
  if [[ -d pprof-data ]]; then
    cp -r pprof-data "${ARTIFACT_DIR}/"
    echo "Copied pprof-data to ${ARTIFACT_DIR}/"
  fi
fi
