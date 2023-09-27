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
GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

git clone https://github.com/cloud-bulldozer/e2e-benchmarking --depth=1
pushd e2e-benchmarking/workloads/router-perf-v2
# UUID Generation
UUID="perfscale-cpt-$(uuidgen)"
export UUID
# ES configuration
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ES_INDEX='router-test-results'
# Environment setup
export LARGE_SCALE_THRESHOLD='24'
export TERMINATIONS='mix'
export DEPLOYMENT_REPLICAS='1'
export SERVICE_TYPE='NodePort'
export NUMBER_OF_ROUTERS='2'
export HOST_NETWORK='true'
export NODE_SELECTOR='{node-role.kubernetes.io/worker: }'
# Benchmark configuration
export RUNTIME='60'
export SAMPLES='2'
export KEEPALIVE_REQUESTS='0 1 50'
export LARGE_SCALE_ROUTES='500'
export LARGE_SCALE_CLIENTS='1 80'
export LARGE_SCALE_CLIENTS_MIX='1 25'
export SMALL_SCALE_CLIENTS='1 400'
export SMALL_SCALE_CLIENTS_MIX='1 125'

export GEN_CSV='true'

export EMAIL_ID_FOR_RESULTS_SHEET='ocp-perfscale-qe@redhat.com'

OUTPUT_FILE="index_data.json"
rm -rf "${SHARED_DIR}/${OUTPUT_FILE:?}"
./ingress-performance.sh 

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/index_data.json ${SHARED_DIR}/index_data.json