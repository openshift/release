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
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/${DSC_NAME} --timeout=9000s 

# Verify RHOAI operator installation
namespace="openshift-operators"
timeout=400s
label_selectors=("control-plane=authorino-operator" "name=istio-operator")
echo "Wait For Pods To Be Ready"
for label_selector in "${label_selectors[@]}"; do
  oc wait --for=condition=ready=true pod -l ${label_selector} -n ${namespace} --timeout=${timeout}
done

namespace="openshift-serverless"
label_selectors=("name=knative-openshift" "name=knative-openshift-ingress" "name=knative-operator")
for label_selector in "${label_selectors[@]}"; do
  oc wait --for=condition=ready=true pod -l ${label_selector} -n ${namespace} --timeout=${timeout}
done

echo "Wait For Deployment Replica To Be Ready"
namespace="redhat-ods-applications"
label_selectors=("app=rhods-dashboard" "app=notebook-controller" "app.kubernetes.io/name=modelmesh-controller" "app.kubernetes.io/name=data-science-pipelines-operator" "control-plane=kserve-controller-manager" "app.kubernetes.io/part-of=model-registry-operator" "app.kubernetes.io/part-of=kueue" "app.kubernetes.io/part-of=codeflare" "app.kubernetes.io/part-of=ray" "pp=odh-model-controller")
for label_selector in "${label_selectors[@]}"; do
  oc get deployment -l ${label_selector} -n ${namespace} -o json | jq -e '.status | .replicas == .readyReplicas'
done

sleep 200
echo "OpenShfit AI Operator is deployed successfully"
