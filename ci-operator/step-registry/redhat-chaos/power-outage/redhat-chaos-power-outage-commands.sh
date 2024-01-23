#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
pushd /tmp

git clone https://github.com/redhat-chaos/krkn-hub.git
pushd krkn-hub/

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG

mkdir -p $HOME/.aws
cat "/secret/telemetry/.awscred" > $HOME/.aws/config
cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
ls -al /secret/telemetry/

# read passwords from vault
telemetry_password=$(cat "/secret/telemetry/telemetry_password")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password
export AWS_DEFAULT_REGION=us-west-2

chmod +x ./prow/power-outage/prow_run.sh
./prow/power-outage/prow_run.sh
rc=$?
echo "Finished running power outages"
echo "Return code: $rc"
