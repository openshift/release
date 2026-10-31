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

# Set AWS credentials from cluster profile for --external-aws-infra
AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_ACCESS_KEY_ID=$(grep aws_access_key_id "${AWS_CREDS}" | awk '{print $3}')
export AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key "${AWS_CREDS}" | awk '{print $3}')
export AWS_DEFAULT_REGION="${AWS_REGION}"

# ES credentials from vault
ES_HOST=""
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
  ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"

# Install Go 1.25
GO_VERSION="1.25.0"
curl -sLO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
export PATH=$PATH:/usr/local/go/bin
go version

# Clone kube-burner-ocp with --external-aws-infra support
WORKDIR=$(mktemp -d)
git clone -b "${KUBE_BURNER_OCP_BRANCH}" "${KUBE_BURNER_OCP_REPO}" "${WORKDIR}/kube-burner-ocp"
pushd "${WORKDIR}/kube-burner-ocp"

make clean; make build

# Run Scenario B with automated AWS infra creation
bin/amd64/kube-burner-ocp cudn-density \
  --bgp=false \
  --iterations="${ITERATIONS}" \
  --namespaces-per-cudn=1 \
  --external-aws-infra=true \
  --aws-region="${AWS_REGION}" \
  --aws-instance-type="${AWS_INSTANCE_TYPE}" \
  --aws-max-targets="${AWS_MAX_TARGETS}" \
  --es-server="${ES_SERVER}" \
  --es-index="${ES_INDEX}" \
  --gc="${GC}" \
  --log-level=debug \
  --timeout="${TIMEOUT}" \
  --burst="${BURST}" \
  --qps="${QPS}" \
  --ignore-health-check

popd
