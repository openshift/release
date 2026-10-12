#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# cloud-controller-manager credentials manifest
CCM_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/powervs-cloud-controller-manager-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-cloud-controller-manager-powervs-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: powervs-credentials
  namespace: openshift-cloud-controller-manager
stringData:
  ibmcloud_api_key: ${CCM_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${CCM_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-csi-drivers credentials manifest
CSID_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/powervs-cluster-csi-drivers-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-cluster-csi-drivers-powervs-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: powervs-credentials
  namespace: openshift-cluster-csi-drivers
stringData:
  ibmcloud_api_key: ${CSID_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${CSID_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-image-registry-operator credentials manifest
IRO_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/powervs-image-registry-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-image-registry-installer-powervs-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: installer-powervs-credentials
  namespace: openshift-image-registry
stringData:
  ibmcloud_api_key: ${IRO_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IRO_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-ingress-operator credentials manifest
IO_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/powervs-ingress-operator-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-ingress-operator-powervs-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: powervs-credentials
  namespace: openshift-ingress-operator
stringData:
  ibmcloud_api_key: ${IO_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IO_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# machine-api credentials manifest
MA_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/powervs-machine-api-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-machine-api-powervs-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: powervs-credentials
  namespace: openshift-machine-api
stringData:
  ibmcloud_api_key: ${MA_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${MA_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF
