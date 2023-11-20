#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

source "${SHARED_DIR}/infra_resources.env"

OCI_CCM_NAMESPACE=oci-cloud-controller-manager
CCM_RESOURCE="DaemonSet/oci-cloud-controller-manager"
CCM_REPLICAS_COUNT=3

echo "export CCM_NAMESPACE=$OCI_CCM_NAMESPACE" >> $SHARED_DIR/ccm.env
echo "export CCM_RESOURCE=$CCM_RESOURCE" >> $SHARED_DIR/ccm.env
echo "export CCM_REPLICAS_COUNT=$CCM_REPLICAS_COUNT" >> $SHARED_DIR/ccm.env

echo_date "Downloading CCM from external documentation"
wget -qO $SHARED_DIR/oci-ccm.yml \
  https://raw.githubusercontent.com/oracle-quickstart/oci-openshift/main/custom_manifests/manifests/oci-ccm.yml

echo_date "Downloaded!"
echo "$SHARED_DIR/oci-ccm.yml" >> ccm-manifests.txt


echo_date "Creating CCM Secret Config"
# Review the defined vars
cat <<EOF>/dev/stdout
OCI_CLUSTER_REGION=$PROVIDER_REGION
VCN_ID=$VCN_ID
SUBNET_ID_PUBLIC=$SUBNET_ID_PUBLIC
EOF

cat <<EOF > /tmp/oci-secret-cloud-provider.yaml
auth:
  region: $OCI_CLUSTER_REGION
useInstancePrincipals: true
compartment: $COMPARTMENT_ID_OPENSHIFT
vcn: $VCN_ID
loadBalancer:
  securityListManagementMode: None
  subnet1: $SUBNET_ID_PUBLIC
EOF

cat <<EOF > ${ARTIFACT_DIR}/manifests/oci-01-ccm-00-secret.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: oci-cloud-controller-manager
  namespace: $OCI_CCM_NAMESPACE
data:
  cloud-provider.yaml: $(base64 -w0 < /tmp/oci-secret-cloud-provider.yaml)
EOF
echo "${ARTIFACT_DIR}/manifests/oci-01-ccm-00-secret.yaml" >> ${SHARED_DIR}/ccm-manifests.txt

echo_date "CCM Secret Config Created"
