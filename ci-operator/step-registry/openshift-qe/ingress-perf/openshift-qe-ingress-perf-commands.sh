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

# Clone the e2e repo
git clone https://github.com/cloud-bulldozer/e2e-benchmarking
pushd e2e-benchmarking/workloads/ingress-perf

# ES Configuration
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ES_INDEX="ingress-performance"

rm -f ${SHARED_DIR}/index.json

# Start the Workload
./run.sh

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/index_data.json ${SHARED_DIR}/index_data.json

echo "{'ingress-perf': \"$CONFIG\"}" > workload.json 
if [ -f "${SHARED_DIR}/perfscale_run.json" ]; then
    result=$(jq -s add workload.json ${SHARED_DIR}/perfscale_run.json)
    echo $result > ${SHARED_DIR}/perfscale_run.json
else
    cp workload.json ${SHARED_DIR}/perfscale_run.json
fi
