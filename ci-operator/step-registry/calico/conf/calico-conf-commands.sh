#!/bin/bash

set -xeuo pipefail

if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
  sed -i "s/networkType: .*/networkType: Calico/" "${SHARED_DIR}/install-config.yaml"
fi

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: Calico
  serviceNetwork:
  - 172.30.0.0/16
EOF

# Apply AWS-specific Secret.
case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov)
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  aws configure export-credentials --format env > /tmp/aws_creds
  set +x
  source /tmp/aws_creds
  key=$(echo -n "$AWS_ACCESS_KEY_ID" | base64 --wrap=0)
  pass=$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64 --wrap=0)
  cat > "${SHARED_DIR}/manifest_aws-creds-secret.yaml" <<EOF
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
esac

calico_dir=/tmp/calico
mkdir $calico_dir

wget -qO- "https://github.com/projectcalico/calico/releases/download/v${CALICO_VERSION}/ocp.tgz" | \
  tar xvz --strip-components=1 -C $calico_dir

operator_yaml=$(find $calico_dir -name "02-tigera-operator*")

tigera_dir=/tmp/tigera
mkdir $tigera_dir

TIGERA_OPERATOR_VERSION=$(yq-v4 '.spec.template.spec.containers[] | select(.name == "tigera-operator").env[] | select(.name == "TIGERA_OPERATOR_INIT_IMAGE_VERSION") | .value' "${operator_yaml}")
wget -qO- "https://github.com/tigera/operator/archive/refs/tags/${TIGERA_OPERATOR_VERSION}.tar.gz" | \
  tar xvz --strip-components=1 -C $tigera_dir

# Install manually the CRDs that we need immediately. The rest will be installed by Tigera operator.
for crd in "operator.tigera.io_installations.yaml" "operator.tigera.io_apiservers.yaml"; do
  cp "${tigera_dir}/pkg/crds/operator/${crd}" "${SHARED_DIR}/manifest_00-${crd}"
done

# Install namespaces, operator, custom resources Installation and ApiServer.
while IFS= read -r src; do
  cp "$src" "${SHARED_DIR}/manifest_$(basename "$src")"
done <<< "$(find $calico_dir -name "00*" -o -name "01*" -o -name "02*")"
