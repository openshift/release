#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export NAME=mycluster.k8s.local
export KOPS_STATE_STORE=s3://my-kops-state-store

curl -Lo kops https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | grep tag_name | cut -d '"' -f 4)/kops-linux-amd64

./kops create cluster ${NAME} \
  --cloud=aws \
  --zones=us-west-2a \
  --yes

kubectl get node
ls ~/.kube/config

./kops delete cluster --name=${NAME} --yes
