#!/bin/bash

set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}
set_proxy

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
mv $KUBECONFIG "${SHARED_DIR}/kubeconfig"

# clear vpc peering if exists
if test -s "${SHARED_DIR}/vpc_peering_id" ; then
  vpc_peering_id=$(cat "$SHARED_DIR/vpc_peering_id")
  aws ec2 delete-vpc-peering-connection --region ${REGION} --vpc-peering-connection-id ${vpc_peering_id}
fi

# clear the capi hcp proxy settings
if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
  rm -f "${SHARED_DIR}/proxy-conf.sh"
fi
