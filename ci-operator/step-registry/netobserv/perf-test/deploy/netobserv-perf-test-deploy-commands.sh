#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x 

# curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip"
# unzip awscli-bundle.zip  
# awscli-bundle/install -b /bin/aws
# export PATH=$PATH:/bin
# mkdir -p $HOME/.aws
which aws
cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
aws_region=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION=$aws_region
source scripts/netobserv.sh
deploy_lokistack
deploy_kafka
deploy_netobserv
createFlowCollector "-p KafkaConsumerReplicas=${KAFKA_CONSUMER_REPLICAS}"
