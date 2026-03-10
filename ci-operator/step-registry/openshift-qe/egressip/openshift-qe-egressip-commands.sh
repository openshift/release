#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

# Create the "external servers" in the bastion host
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   podman stop $(podman ps | grep nginxecho | awk '{ print $1 }') || echo 'No containers to stop'
   podman rm $(podman ps -a | grep nginxecho | awk '{ print $1 }') || echo 'No containers to delete'
   for port in {9002..9020}; do
      podman run --network=host -d -e LISTEN_PORT=\$port quay.io/cloud-bulldozer/nginxecho:latest
   done
"

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
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper
export WORKLOAD=egressip

EXTRA_FLAGS="--gc-metrics=true --pod-ready-threshold=$POD_READY_THRESHOLD --addresses-per-iteration=$ADDRESSES_PER_ITERATION --profile-type=${PROFILE_TYPE}"

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export EXTRA_FLAGS


# Run workload immediately
./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi

# Cleanup the "external servers" in the bastion host
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   podman stop $(podman ps | grep nginxecho | awk '{ print $1 }')
   podman rm $(podman ps -a | grep nginxecho | awk '{ print $1 }')
"