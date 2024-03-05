#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version


ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")


export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ELASTIC_INDEX=krkn_chaos_ci


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
#aws_access_key_id=$(cat "/secret/telemetry/aws_access_key_id")
#aws_secret_access_key=$(cat "/secret/telemetry/aws_secret_access_key")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password
export AWS_DEFAULT_REGION=us-west-2
#export AWS_ACCESS_KEY_ID=$aws_access_key_id
#export AWS_SECRET_ACCESS_KEY=$aws_secret_access_key

chmod +x ./node-disruptions/prow_run.sh
./node-disruptions/prow_run.sh
rc=$?
echo "Finished running node disruptions"
echo "Return code: $rc"
