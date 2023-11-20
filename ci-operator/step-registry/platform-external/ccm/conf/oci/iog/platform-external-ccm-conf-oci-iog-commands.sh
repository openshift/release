#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function turn_down() {
  touch /tmp/ccm.done
}
trap turn_down EXIT

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/infra_resources.env"
OCI_CCM_NAMESPACE=oci-cloud-controller-manager

echo "export CCM_NAMESPACE=$OCI_CCM_NAMESPACE" >> $SHARED_DIR/ccm.env
echo "export CCM_DEPLOYMENT=$CCM_DEPLOYMENT" >> $SHARED_DIR/ccm.env
echo "export CCM_REPLICAS_COUNT=$CCM_REPLICAS_COUNT" >> $SHARED_DIR/ccm.env

echo "======================="
echo "Installing dependencies"
echo "======================="

export PATH=$PATH:/tmp

echo_date "Checking/installing yq3..."
if ! [ -x "$(command -v yq3)" ]; then
  wget -qO /tmyq3 https://github.com/mikefarayq/releases/download/3.4.yq_linux_amd64
  chmod u+x /tmyq3
fi
which yq3
ln -svf /tmyq3 /tmp

### 

echo "${ARTIFACT_DIR}/manifests/oci-00-ccm-namespace.yaml" >> ccm-manifests.txt
cat <<EOF > ${ARTIFACT_DIR}/manifests/oci-00-ccm-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: $OCI_CCM_NAMESPACE
  annotations:
    workload.openshift.io/allowed: management
    include.release.openshift.io/self-managed-high-availability: "true"
  labels:
    "pod-security.kubernetes.io/enforce": "privileged"
    "pod-security.kubernetes.io/audit": "privileged"
    "pod-security.kubernetes.io/warn": "privileged"
    "security.openshift.io/scc.podSecurityLabelSync": "false"
    "openshift.io/run-level": "0"
    "pod-security.kubernetes.io/enforce-version": "v1.24"
EOF

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
echo "${ARTIFACT_DIR}/manifests/oci-01-ccm-00-secret.yaml" >> ccm-manifests.txt

CCM_RELEASE=v1.26.0

wget -qO /tmp/oci-cloud-controller-manager-rbac.yaml \
  https://github.com/oracle/oci-cloud-controller-manager/releases/download/${CCM_RELEASE}/oci-cloud-controller-manager-rbac.yaml

wget -qO /tmp/oci-cloud-controller-manager.yaml \
  https://github.com/oracle/oci-cloud-controller-manager/releases/download/${CCM_RELEASE}/oci-cloud-controller-manager.yaml


yq ". | select(.kind==\"ServiceAccount\").metadata.namespace=\"$OCI_CCM_NAMESPACE\"" \
  /tmp/oci-cloud-controller-manager-rbac.yaml \
  > /tmp/oci-cloud-controller-manager-rbac_patched.yaml

cat << EOF > /tmp/oci-ccm-rbac_patch_crb-subject.yaml
- kind: ServiceAccount
  name: cloud-controller-manager
  namespace: $OCI_CCM_NAMESPACE
EOF

yq eval-all -i ". | select(.kind==\"ClusterRoleBinding\").subjects *= load(\"/tmp/oci-ccm-rbac_patch_crb-subject.yaml\")" \
  /tmp/oci-cloud-controller-manager-rbac_patched.yaml

yq -s '"/tmp/oci-01-ccm-01-rbac_" + $index' /tmp/oci-cloud-controller-manager-rbac_patched.yaml &&\
mv -v /tmp/oci-01-ccm-01-rbac_*.yml ${ARTIFACT_DIR}/manifests/
echo "${ARTIFACT_DIR}/manifests/oci-01-ccm-00-secret.yaml" >> ${SHARED_DIR}/ccm-manifests.txt

cat <<EOF > /tmp/oci-cloud-controller-manager-ds_patch1.yaml
metadata:
  namespace: $OCI_CCM_NAMESPACE
spec:
  template:
    spec:
      tolerations:
        - key: node.kubernetes.io/not-ready
          operator: Exists
          effect: NoSchedule
EOF

# Create the containers' env patch
cat <<EOF > /tmp/oci-cloud-controller-manager-ds_patch2.yaml
spec:
  template:
    spec:
      containers:
        - env:
          - name: KUBERNETES_PORT
            value: "tcp://api-int.$CLUSTER_NAME.$BASE_DOMAIN:6443"
          - name: KUBERNETES_PORT_443_TCP
            value: "tcp://api-int.$CLUSTER_NAME.$BASE_DOMAIN:6443"
          - name: KUBERNETES_PORT_443_TCP_ADDR
            value: "api-int.$CLUSTER_NAME.$BASE_DOMAIN"
          - name: KUBERNETES_PORT_443_TCP_PORT
            value: "6443"
          - name: KUBERNETES_PORT_443_TCP_PROTO
            value: "tcp"
          - name: KUBERNETES_SERVICE_HOST
            value: "api-int.$CLUSTER_NAME.$BASE_DOMAIN"
          - name: KUBERNETES_SERVICE_PORT
            value: "6443"
          - name: KUBERNETES_SERVICE_PORT_HTTPS
            value: "6443"
EOF

# Merge required objects for the pod's template spec
yq eval-all '. as $item ireduce ({}; . *+ $item)' \
  /tmp/oci-cloud-controller-manager.yaml \
  /tmp/oci-cloud-controller-manager-ds_patch1.yaml \
  > /tmp/oci-cloud-controller-manager-ds_patched1.yaml

# Merge required objects for the pod's containers spec
yq eval-all '.spec.template.spec.containers[] as $item ireduce ({}; . *+ $item)' \
  /tmp/oci-cloud-controller-manager-ds_patched1.yaml \
  /tmp/oci-cloud-controller-manager-ds_patch2.yaml \
  > ./oci-cloud-controller-manager-ds_patched2.yaml

# merge patches to ${INSTALL_DIR}/manifests/oci-01-ccm-02-daemonset.yaml
yq eval-all '.spec.template.spec.containers[] *= load("/tmp/oci-cloud-controller-manager-ds_patched2.yaml")' \
  /tmp/oci-cloud-controller-manager-ds_patched1.yaml \
  > ${ARTIFACT_DIR}/manifests/oci-01-ccm-02-daemonset.yaml

echo "${ARTIFACT_DIR}/manifests/oci-01-ccm-02-daemonset.yaml" >> ${SHARED_DIR}/ccm-manifests.txt

tree $ARTIFACT_DIR/manifests/

#oc create -f $ARTIFACT_DIR/manifests/