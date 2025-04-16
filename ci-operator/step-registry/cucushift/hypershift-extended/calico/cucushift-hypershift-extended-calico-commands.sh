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
  if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
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
# Install Operators
find $calico_dir -name "02*" -print0 | xargs -0 -n1 oc apply -f

# Do not manage CRDs by the operator as we can't wait for the
# Operator to be up and install the CRDs.
operator_yaml=$(find $calico_dir -name "02-tigera-operator*")
sed "s/manage-crds=true/manage-crds=false/" "${operator_yaml}" | oc apply -f -

tigera_dir=/tmp/tigera
mkdir $tigera_dir

TIGERA_OPERATOR_VERSION=$(yq-v4 '.spec.template.spec.containers[] | select(.name == "tigera-operator").env[] | select(.name == "TIGERA_OPERATOR_INIT_IMAGE_VERSION") | .value' "${operator_yaml}")
wget -qO- "https://github.com/tigera/operator/archive/refs/tags/${TIGERA_OPERATOR_VERSION}.tar.gz" | \
  tar xvz --strip-components=1 -C $tigera_dir

# Install CRDs manually
find ${tigera_dir}/pkg/crds/operator -name "*.yaml" -print0 | xargs -0 -n1 oc apply -f
find ${tigera_dir}/pkg/crds/calico -name "*.yaml" -print0 | xargs -0 -n1 oc apply -f

# Install custom resources
find $calico_dir -name "01*" -print0 | xargs -0 -n1 oc apply -f
