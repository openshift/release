#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG

mkdir -p $HOME/.aws
cat "/secret/telemetry/.awscred" > $HOME/.aws/config
cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
ls -al /secret/telemetry/

ES_PASSWORD=$(cat "/secret/es/password" || "")
ES_USERNAME=$(cat "/secret/es/username" || "")

export ES_PASSWORD
export ES_USERNAME

export ELASTIC_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# # read passwords from vault
telemetry_password=$(cat "/secret/telemetry/telemetry_password")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password
export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"

NODE_NAME=$(set +o pipefail; oc get nodes --no-headers | head -n 1 | awk '{print $1}')
rc=$?
echo "Node name return code: $rc"

VPC_ID=$(aws ec2 describe-instances --filter Name=private-dns-name,Values=$NODE_NAME  --query 'Reservations[*].Instances[*].NetworkInterfaces[*].VpcId' --output text)
rc=$?
echo "VPC return code: $rc"
export VPC_ID

SUBNET_ID=$(aws ec2 describe-subnets --filter Name=vpc-id,Values=$VPC_ID --query 'Subnets[*].SubnetId' --max-items 2) 
rc=$?
echo "Subnet return code: $rc"
export SUBNET_ID

./zone-outages/prow_run.sh
rc=$?
echo "Finished running zone outages"
echo "Return code: $rc"
