#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

export KUBE_BURNER_URL="https://github.com/cloud-bulldozer/kube-burner/releases/download/v0.17.3/kube-burner-0.17.3-Linux-x86_64.tar.gz"

git clone https://github.com/cloud-bulldozer/e2e-benchmarking/ --depth=1
pushd e2e-benchmarking/workloads/kube-burner
export WORKLOAD=concurrent-builds

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

rm -f ${SHARED_DIR}/index.json

./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/index_data.json ${SHARED_DIR}/index_data.json

echo "{\"$WORKLOAD\": \"$BUILD_LIST\"}" > workload.json 
if [ -f "${SHARED_DIR}/perfscale_run.json" ]; then
    result=$(jq -s add workload.json ${SHARED_DIR}/perfscale_run.json)
    echo $result > ${SHARED_DIR}/perfscale_run.json
else
    cp workload.json ${SHARED_DIR}/perfscale_run.json
fi
