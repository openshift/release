#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# cloud-controller-manager credentials manifest
CCM_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cloud-controller-manager-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-cloud-controller-manager-ibm-cloud-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ibm-cloud-credentials
  namespace: openshift-cloud-controller-manager
stringData:
  ibmcloud_api_key: ${CCM_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${CCM_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-csi-drivers credentials manifest
CSID_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cluster-csi-drivers-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-cluster-csi-drivers-ibm-cloud-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ibm-cloud-credentials
  namespace: openshift-cluster-csi-drivers
stringData:
  ibmcloud_api_key: ${CSID_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${CSID_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-image-registry-operator credentials manifest
IRO_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-image-registry-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-image-registry-installer-cloud-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: installer-cloud-credentials
  namespace: openshift-image-registry
stringData:
  ibmcloud_api_key: ${IRO_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IRO_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# cluster-ingress-operator credentials manifest
IO_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-ingress-operator-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-ingress-operator-cloud-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-ingress-operator
stringData:
  ibmcloud_api_key: ${IO_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${IO_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF

# machine-api credentials manifest
MA_API_KEY="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-machine-api-api-key")"
cat >> "${SHARED_DIR}/manifest_openshift-machine-api-ibmcloud-credentials-credentials.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ibmcloud-credentials
  namespace: openshift-machine-api
stringData:
  ibmcloud_api_key: ${MA_API_KEY}
  ibm-credentials.env: |
    IBMCLOUD_APIKEY=${MA_API_KEY}
    IBMCLOUD_AUTHTYPE=iam
type: Opaque
EOF
