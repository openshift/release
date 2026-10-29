#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat >> "${SHARED_DIR}/manifest_cluster-ingress-default-ingresscontroller.yaml" << EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  endpointPublishingStrategy:
    loadBalancer:
      providerParameters:
        gcp:
          clientAccess: Global
        type: GCP
      scope: Internal
    type: LoadBalancerService
EOF
