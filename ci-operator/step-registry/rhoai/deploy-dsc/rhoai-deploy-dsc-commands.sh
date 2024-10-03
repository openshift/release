#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Deploying a DataScience Cluster"
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: "${DSC_NAME}"
  labels:
    app.kubernetes.io/name: datasciencecluster
    app.kubernetes.io/instance: "${DSC_NAME}"
    app.kubernetes.io/part-of: "${OPERATOR_NAME}"
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/created-by: "${OPERATOR_NAME}"
spec:
  components:
    codeflare:
      managementState: Managed
    kserve:
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Managed
        name: knative-serving
      managementState: Managed
    trustyai:
      managementState: Removed
    ray:
      managementState: Managed
    kueue:
      managementState: Managed
    workbenches:
      managementState: Managed
    dashboard:
      managementState: Managed
    modelmeshserving:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    trainingoperator:
      managementState: Removed
EOF

echo "⏳ Wait for DataScientCluster to be deployed"
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/${DSC_NAME} --timeout=6000s 

echo "OpenShfit AI Operator is deployed successfully"