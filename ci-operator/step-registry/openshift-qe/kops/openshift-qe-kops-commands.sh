#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export NAME=mycluster.k8s.local
export KOPS_STATE_STORE=s3://my-kops-state-store

kops create cluster ${NAME} \
  --cloud=aws \
  --zones=us-west-2a \
  --yes
  
kops delete cluster --name=${NAME} --yes
