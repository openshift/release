#!/bin/bash

set -xeuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

# Install AWS credentials for the tigera-operator. It creates additional
# inbound rules for the existing Security Group to allow traffic between its components.
platform=$(oc get infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
if [[ "$platform" == "AWS" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
  if [[ "${HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT:-}" == "true" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  fi
  aws configure export-credentials --format env > /tmp/aws_creds
  set +x
  source /tmp/aws_creds
  key=$(echo -n "$AWS_ACCESS_KEY_ID" | base64 --wrap=0)
  pass=$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64 --wrap=0)
  oc apply -f - <<EOF
apiVersion: v1
data:
  aws_access_key_id: ${key}
  aws_secret_access_key: ${pass}
kind: Secret
metadata:
  name: aws-creds
  namespace: kube-system
type: Opaque
EOF
  set -x
fi

calico_dir=/tmp/calico
mkdir $calico_dir

wget -qO- "https://github.com/projectcalico/calico/releases/download/v${CALICO_VERSION}/ocp.tgz" | \
  tar xvz --strip-components=1 -C $calico_dir

# Create namespaces
find $calico_dir -name "00*" -print0 | xargs -0 -n1 oc apply -f
# Install operator
find $calico_dir -name "02*" -print0 | xargs -0 -n1 oc apply -f

timeout 15m bash -c 'until oc get crd installations.operator.tigera.io; do sleep 15; done'
oc wait --for condition=established --timeout=60s crd installations.operator.tigera.io

timeout 15m bash -c 'until oc get crd apiservers.operator.tigera.io; do sleep 15; done'
oc wait --for condition=established --timeout=60s crd apiservers.operator.tigera.io

# Install API Server
oc apply -f "${calico_dir}/01-cr-apiserver.yaml"

# Install Calico with specific setting for node address auto-detection.
# The specific setting is required as some tests create NetworkAttachmentDefinitions
# which add network interfaces to the host. Calico then incorrectly chooses this interface
# and breaks connectivity between nodes. By choosing NodeInternalIP, the address picked by
# Calico remains same throughout the lifecycle.
oc apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  variant: Calico
  calicoNetwork:
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP
EOF
