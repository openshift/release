#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

git clone --branch $BRANCH $ORION_REPO
pushd orion

pip install -r requirements.txt

if [[ ${ES_TYPE} == "qe" ]]; then
    ES_PASSWORD=$(cat "/secret/qe/password")
    ES_USERNAME=$(cat "/secret/qe/username")
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
   
else

    ES_PASSWORD=$(cat "/secret/internal/password")
    ES_USERNAME=$(cat "/secret/internal/username")
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@opensearch.app.intlab.redhat.com"
fi 

pip install .
export  EXTRA_FLAGS=""
if [[ -n "$UUID" ]]; then
    export EXTRA_FLAGS+=" --uuid ${UUID}"
fi
if [ ${HUNTER_ANALYZE} == "true" ]; then
 export EXTRA_FLAGS+=" --hunter-analyze"
fi

orion --config $CONFIG $EXTRA_FLAGS

cat *.csv