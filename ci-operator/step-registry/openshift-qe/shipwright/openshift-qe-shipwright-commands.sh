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


REPO_URL="https://github.com/chentex/shipwright-perf-test";
git clone $REPO_URL
pushd shipwright-perf-test

# Configure Elasticsearch server
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

# Configure the namespace prefix and iteration range and other parameters
export NAMESPACE=${NAMESPACE}
export START=${START}
export END=${END}
export BURST_SIZE=${BURST_SIZE}
export SLEEP_TIME=${SLEEP_TIME}

# Run the Shipwright test suite 
./shipwright.sh

# Install pandas to generate the results in a CSV file
pip install pandas

oc get buildrun -A -o json | jq -r '.items[] | [.metadata.name, .status.startTime, .status.completionTime, (.status.conditions[] | select(.type=="Succeeded") | .status)] | @tsv' \
    | grep ccbuildrun- > results-shipwright.csv

python process_shipwright_results.py results-shipwright.csv
