#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

oc version
oc get nodes -L topology.kubernetes.io/zone

# ES credentials from vault
ES_HOST=${ES_HOST:-""}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
  ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"

# Install Go
GO_VERSION="1.25.0"
curl -sLO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
export PATH=$PATH:/usr/local/go/bin
go version

# Clone and build midterm_scenario_a
WORKDIR=$(mktemp -d)
git clone -b midterm_scenario_a https://github.com/venkataanil/kube-burner-ocp.git "${WORKDIR}/kube-burner-ocp"
pushd "${WORKDIR}/kube-burner-ocp"

# Fix nginx image (quay.io/cloud-bulldozer/nginx has override binary issue on OCP 5.0+)
sed -i 's|quay.io/cloud-bulldozer/nginx:latest|quay.io/sninganu/nginx:latest|g' \
  cmd/config/cudn-density/deployment-server.yml

make clean; make build

# Run Scenario A
bin/amd64/kube-burner-ocp cudn-density \
  --log-level=debug \
  --qps="${QPS}" \
  --burst="${BURST}" \
  --timeout="${TIMEOUT}" \
  --layer3=false \
  --namespaces-per-cudn=1 \
  --gc-metrics=false \
  --pod-ready-threshold="${POD_READY_THRESHOLD}" \
  --profile-type=both \
  --pprof=true \
  --job-pause="${JOB_PAUSE}" \
  --iterations="${ITERATIONS}" \
  --gc="${GC}" \
  --es-server="${ES_SERVER}" \
  --es-index="${ES_INDEX}" \
  --ignore-health-check

popd
