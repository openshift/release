#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Read AWS credentials without xtrace to avoid exposing secrets in logs
set +x
AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
AWS_ACCESS_KEY_ID=$(grep aws_access_key_id "${AWS_CREDS}" | awk '{print $3}')
export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key "${AWS_CREDS}" | awk '{print $3}')
export AWS_SECRET_ACCESS_KEY
# AWS_DEFAULT_REGION not set here — SDK auto-detects from cluster metadata

# Read ES credentials without xtrace
ES_HOST="search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
  ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
# Export as env var — do not pass on command line to avoid log exposure
export ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"
set -x

# Install Go 1.25 if not already present
GO_VERSION="1.25.0"
if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null)" != *"go${GO_VERSION}"* ]]; then
  curl -sSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /tmp -xzf -
  export PATH=$PATH:/tmp/go/bin
fi
go version

# Clone kube-burner-ocp pinned to immutable commit SHA
WORKDIR=$(mktemp -d)
git clone "${KUBE_BURNER_OCP_REPO}" "${WORKDIR}/kube-burner-ocp"
pushd "${WORKDIR}/kube-burner-ocp"
git checkout "${KUBE_BURNER_OCP_COMMIT}"

rm -f bin/amd64/kube-burner-ocp
  mkdir -p bin/amd64
  CGO_ENABLED=0 GOARCH=amd64 go build -o bin/amd64/kube-burner-ocp ./cmd/

# Detect actual cluster AWS region from infrastructure CR (Boskos assigns any region)
AWS_REGION=$(oc get infrastructure cluster   -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || echo "us-east-2")
echo "Detected cluster AWS region: ${AWS_REGION}"

# Run Scenario B — disable xtrace while passing ES_SERVER to avoid credential exposure in logs
set +x
bin/amd64/kube-burner-ocp cudn-density \
  --bgp=false \
  --iterations="${ITERATIONS}" \
  --namespaces-per-cudn=1 \
  --external-aws-infra=true \
  --aws-region="${AWS_REGION}" \
  --aws-instance-type="${AWS_INSTANCE_TYPE}" \
  --aws-instance-id-file="${SHARED_DIR}/ext_instance_id" \
  --aws-max-targets="${AWS_MAX_TARGETS}" \
  --es-server="${ES_SERVER}" \
  --es-index="${ES_INDEX}" \
  --gc="${GC}" \
  --log-level=debug \
  --timeout="${TIMEOUT}" \
  --burst="${BURST}" \
  --qps="${QPS}" \
  --pod-ready-threshold="${POD_READY_THRESHOLD}" \
  --ignore-health-check
set -x

# Export key log data to SHARED_DIR for collect-logs step (different container, separate /tmp)
KB_LOG=$(find "${WORKDIR}/kube-burner-ocp" -name "kube-burner-ocp-*.log" -print0 2>/dev/null \
  | xargs -0 ls -t 2>/dev/null | head -1 || true)
if [ -n "${KB_LOG}" ]; then
  grep "Group 2: Creating object replicas from iteration" "${KB_LOG}" | head -1 \
    > "${SHARED_DIR}/kb_group2_line.txt" || true
  grep -h "Ready 99th\|Ready P99\|cudn-density: Ready" "${KB_LOG}" \
    > "${SHARED_DIR}/kb_ready_latency.txt" || true
  echo "Exported Group 2 line and latency data to SHARED_DIR"
fi

popd
