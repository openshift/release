#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

if [[ ! -f "${SHARED_DIR}/frr-peer-address" ]]; then
  echo "ERROR: ${SHARED_DIR}/frr-peer-address not found; run openshift-qe-bgp-setup-udn-bgp first" >&2
  exit 1
fi
FRR_PEER_IP=$(cat "${SHARED_DIR}/frr-peer-address")

UUID=$(uuidgen)

EXTRA_FLAGS=""
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=false --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --frr-external-ip=${FRR_PEER_IP}"

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)"
git clone "$REPO_URL" $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export WORKLOAD=udn-bgp
export ITERATIONS
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
export EXTRA_FLAGS UUID

$WAS_TRACING && set -x

for node in $(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}'); do
  echo "Pre-loading image on node ${node}..."
  oc debug "node/${node}" -n default -- chroot /host crictl pull quay.io/cloud-bulldozer/sampleapp:latest
done

set +o errexit
./run.sh
RUN_EXIT_CODE=$?
set -o errexit

METRICS_FOLDER="collected-metrics-${UUID}"
if [[ -f "${METRICS_FOLDER}/jobSummary.json" ]]; then
  cp -r "${METRICS_FOLDER}" "${ARTIFACT_DIR}/"
fi

exit ${RUN_EXIT_CODE}
