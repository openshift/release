#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: pipelines-iib
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: "${PIPELINES_IMAGE}:${PIPELINES_IMAGE_TAG}"
  imagePullSecrets:
    - name: pull-secret
  displayName: pipelines-iib
  publisher: RHTAP-QE
EOF