#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

pushd /tmp

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

EXTRA_FLAGS=""
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE}"

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

# shellcheck disable=SC2087
ssh ${SSH_ARGS} root@"${bastion}" bash -s <<EOF
    export KUBECONFIG=/root/vmno/kubeconfig
    rm -rf ~/e2e-benchmarking
    git clone "$REPO_URL" $TAG_OPTION --depth 1
    pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
    export WORKLOAD=udn-bgp
    export ITERATIONS=72
    export ES_SERVER="$ES_SERVER"
    export EXTRA_FLAGS="$EXTRA_FLAGS"
    ./run.sh
    rm -rf ~/e2e-benchmarking
EOF
