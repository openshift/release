#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -v

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export NAME=mycluster.k8s.local
export KOPS_STATE_STORE=s3://my-kops-state-store

curl -Lo /tmp/kops "https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | jq -r '.tag_name')/kops-linux-amd64"
chmod +x /tmp/kops

./tmp/kops create cluster ${NAME} \
  --cloud=aws \
  --zones=us-west-2a \
  --yes

kubectl get node
ls ~/.kube/config

./tmp/kops delete cluster --name=${NAME} --yes
