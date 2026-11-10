#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
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
REPO_URL="https://github.com/openshift/svt.git";
TAG_OPTION="--branch master";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd svt/storage-csi-perf

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
ls /secret/ga-gsheet
GSHEET_KEY_LOCATION="/secret/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

sa_email=$(jq -r .client_email ${GSHEET_KEY_LOCATION})
echo "$sa_email"

export EMAIL_ID_FOR_RESULTS_SHEET='ocp-perfscale-qe@redhat.com'

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=true --profile-type=${PROFILE_TYPE}"
export EXTRA_FLAGS

rm -f ${SHARED_DIR}/index.json
pip install jq
python3.9 --version
python3.9 -m pip install virtualenv
python3.9 -m virtualenv venv3
source venv3/bin/activate
python3.9 -m pip install pytimeparse futures
pip3 install elasticsearch==7.10.0
pip3 install "numpy<2"
pip3 install requests
python --version
pip3 list
export WORKLOAD=mixed-workload
export TOTAL_WORKLOAD=${ITERATIONS}
pwd
./run.sh

