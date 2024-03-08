#!/bin/bash

set -xeuo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION=${REGION}
export AWS_PAGER=""

# download clusterctl and clusterawsadm
mkdir -p /tmp/bin
export PATH=$PATH:/tmp/bin
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.6.2/clusterctl-linux-amd64 -o /tmp/bin/clusterctl && \
    chmod +x /tmp/bin/clusterctl

curl -L https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/v2.4.0/clusterawsadm-linux-amd64 -o /tmp/bin/clusterawsadm && \
    chmod +x /tmp/bin/clusterawsadm

clusterctl delete --all
clusterawsadm bootstrap iam delete-cloudformation-stack