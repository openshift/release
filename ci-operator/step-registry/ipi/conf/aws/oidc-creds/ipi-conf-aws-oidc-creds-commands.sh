#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
WEB_IDENTITY_TOKEN_FILE="/var/run/secrets/openshift/serviceaccount/token"


cp /var/run/secret/bound-sa-signing-key/service-account.key "${TPREFIX}_bound-service-account-signing-key.key"

cat >> "${MPREFIX}_cluster-authentication-02-config.yaml" << EOF
apiVersion: config.openshift.io/v1
kind: Authentication
metadata:
  name: cluster
spec:
  serviceAccountIssuer: https://do-not-remove-shared-oidc-oidc-discovery.s3.amazonaws.com

EOF

CONFIG="[default]
role_arn = arn:aws:iam::460538899914:role/do-not-remove-shared-oidc-ebs-csi-driver-role
web_identity_token_file = ${WEB_IDENTITY_TOKEN_FILE}
"
BASE64CONFIG=$(echo "${CONFIG}" | base64 -w0)
cat >> "${MPREFIX}_secret-credentials-ebs-csi-driver.yaml" << EOF
apiVersion: v1
data:
  credentials: ${BASE64CONFIG}
kind: Secret
metadata:
  name: ebs-cloud-credentials
  namespace: openshift-cluster-csi-drivers

EOF

CONFIG="[default]
role_arn = arn:aws:iam::460538899914:role/do-not-remove-shared-oidc-image-registry-role
web_identity_token_file = ${WEB_IDENTITY_TOKEN_FILE}
"
BASE64CONFIG=$(echo "${CONFIG}" | base64 -w0)
cat >> "${MPREFIX}_secret-credentials-image-registry.yaml" << EOF
apiVersion: v1
data:
  credentials: ${BASE64CONFIG}
kind: Secret
metadata:
  name: installer-cloud-credentials
  namespace: openshift-image-registry

EOF

CONFIG="[default]
role_arn = arn:aws:iam::460538899914:role/do-not-remove-shared-oidc-ingress-role
web_identity_token_file = ${WEB_IDENTITY_TOKEN_FILE}
"
BASE64CONFIG=$(echo "${CONFIG}" | base64 -w0)
cat >> "${MPREFIX}_secret-credentials-ingress.yaml" << EOF
apiVersion: v1
data:
  credentials: ${BASE64CONFIG}
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-ingress-operator

EOF

CONFIG="[default]
role_arn = arn:aws:iam::460538899914:role/do-not-remove-shared-oidc-machine-api-role
web_identity_token_file = ${WEB_IDENTITY_TOKEN_FILE}
"
BASE64CONFIG=$(echo "${CONFIG}" | base64 -w0)
cat >> "${MPREFIX}_secret-credentials-machine-api.yaml" << EOF
apiVersion: v1
data:
  credentials: ${BASE64CONFIG}
kind: Secret
metadata:
  name: aws-cloud-credentials
  namespace: openshift-machine-api

EOF
