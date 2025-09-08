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

ls /secret
ES_PASSWORD=$(cat "/secret/perfscale-es/password")
export ES_PASSWORD

ES_USERNAME=$(cat "/secret/perfscale-es/username")
export ES_USERNAME

ls /secret/ga-gsheet
GSHEET_KEY_LOCATION="/secret/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

sa_email=$(jq -r .client_email ${GSHEET_KEY_LOCATION})
echo "$sa_email"

export EMAIL_ID_FOR_RESULTS_SHEET='ocp-perfscale-qe@redhat.com'

git clone https://github.com/openshift-eng/ocp-qe-perfscale-ci.git -b write-scale-ci-results

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

jq -r 'to_entries[] | "\(.key)\t\(.value)"' ${SHARED_DIR}/index_data.json |
  while read key val
  do
    cap_key=$(echo $key | awk ' { print toupper($1) }')
    echo "export $cap_key=$val" >> index.sh
  done 

source index.sh
env

pushd ocp-qe-perfscale-ci

pip install -r requirements.txt
pushd write_to_sheet

python prow_write.py