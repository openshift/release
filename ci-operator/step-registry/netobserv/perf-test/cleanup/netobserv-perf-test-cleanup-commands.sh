#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

mkdir -p $HOME/.aws
cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
aws_region=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION=$aws_region

source scripts/netobserv.sh
nukeobserv
