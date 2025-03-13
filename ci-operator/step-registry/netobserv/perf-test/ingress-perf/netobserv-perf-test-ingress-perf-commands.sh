#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail # TODO: check on this with the pipe commands that's could fail
set -x

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"


# oc config view
# oc projects

SERVER=$(grep "server: https" "$KUBECONFIG" | head -1)
API_SERVER_URL=${SERVER##* }
KUBEADMIN_PASSWORD=$(cat "${KUBEADMIN_PASSWORD_FILE}")
TOKEN=$(curl -sk -i -L -X GET --user kubeadmin:"$KUBEADMIN_PASSWORD" "$API_SERVER_URL/oauth/authorize?response_type=token&client_id=openshift-challenging-client" | grep -oP "access_token=\K[^&]*")

echo "API token: $TOKEN"
#check for flowcollector and ebpf-daemonset being ready
FC_STATUS=$(curl -sk -XGET -H "Authorization: Bearer $TOKEN" "$API_SERVER_URL/apis/flows.netobserv.io/v1beta2/flowcollectors/cluster" | jq '.status.conditions[0].type')
while [ "$FC_STATUS" != "\"Ready\"" ]; do
    echo "====> Waiting for flowcollector to be ready"
    sleep 30
    FC_STATUS=$(curl -sk -XGET -H "Authorization: Bearer $TOKEN" "$API_SERVER_URL/apis/flows.netobserv.io/v1beta2/flowcollectors/cluster" | jq '.status.conditions[0].type')
done

ebpfDesiredNumber="1"
ebpfDesiredNumber="0"

while [ "$ebpfNumberAvailable" != "$ebpfDesiredNumber" ]; do
    echo "====> Waiting for ebpf damonset to be ready"
    ebpfDesiredNumber=$(curl -sk -XGET -H "Authorization: Bearer $TOKEN" "$API_SERVER_URL/apis/apps/v1/namespaces/netobserv-privileged/daemonsets/netobserv-ebpf-agent" | jq '.status.desiredNumberScheduled' || echo "1")
    ebpfNumberAvailable=$(curl -sk -XGET -H "Authorization: Bearer $TOKEN" "$API_SERVER_URL/apis/apps/v1/namespaces/netobserv-privileged/daemonsets/netobserv-ebpf-agent" | jq '{.status.numberAvailable}' || echo "0")
    sleep 30
done

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

# ES_PASSWORD=$(cat "/secret/password")
# ES_USERNAME=$(cat "/secret/username")

# Clone the e2e repo
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL "$TAG_OPTION" --depth 1
pushd e2e-benchmarking/workloads/ingress-perf

# ES Configuration
# export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
# export ES_INDEX="ingress-performance"
export ES_SERVER=""

# Start the Workload
./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/index_data.json ${SHARED_DIR}/index_data.json
cp ${SHARED_DIR}/index_data.json ${ARTIFACT_DIR}/ingress-perf-index_data.json
