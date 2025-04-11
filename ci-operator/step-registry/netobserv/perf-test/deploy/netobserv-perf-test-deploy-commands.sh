#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

which aws
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
mkdir -p $HOME/.aws
aws configure set profile default
aws configure set region "$LEASED_RESOURCE"
aws configure get region
aws_region=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION=$aws_region
source scripts/netobserv.sh
deploy_lokistack
deploy_kafka
deploy_netobserv
createFlowCollector "-p KafkaConsumerReplicas=${KAFKA_CONSUMER_REPLICAS}"
