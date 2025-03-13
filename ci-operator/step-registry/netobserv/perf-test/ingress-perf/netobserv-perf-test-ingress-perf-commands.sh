#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"


kubectl config view
kubectl projects

#check for flowcollector and ebpf-daemonset being ready
kubectl get flowcollector/cluster | grep Ready
while [[ $? ]]; do
    echo "====> Waiting for flowcollector to be ready"
    sleep 30
    kubectl get flowcollector/cluster | grep Ready
done

ebpfDesiredNumber="1"
ebpfDesiredNumber="0"

while [[ "$ebpfNumberAvailable" != "$ebpfDesiredNumber" ]]; do
    echo "====> Waiting for ebpf damonset to be ready"
    ebpfDesiredNumber=$(kubectl -n netobserv-privileged  get ds/netobserv-ebpf-agent -o jsonpath='{.status.desiredNumberScheduled}' || echo "1")
    ebpfNumberAvailable=$(kubectl -n netobserv-privileged  get ds/netobserv-ebpf-agent -o jsonpath='{.status.numberAvailable}' || echo "0")
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
rc=$?
echo "{'ingress-perf': $rc}" >> "${SHARED_DIR}"/ingress-perf-observer_status.json

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp "$folder_name"/index_data.json "${SHARED_DIR}"/index_data.json
cp "${SHARED_DIR}"/index_data.json "$SHARED_DIR"/ingress-perf-index_data.json
cp "$SHARED_DIR"/ingress-perf-index_data.json "${ARTIFACT_DIR}"/ingress-perf-index_data.json

echo "Return code: $rc"
exit $rc

