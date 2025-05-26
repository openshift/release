#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Deploying a DataScience Cluster"
csv=$(oc get csv -n default -o json | jq -r '.items[] | select(.metadata.name | startswith("rhods-operator"))')
if [[ -z "${csv}" ]]; then
  echo "Error: Cannot find csv with name 'rhods-operator*'"
  oc get csv -n default
  exit 1
fi

csv_name=$(echo "${csv}" | jq -r '.metadata.name')
echo "Found csv '${csv_name}'"
echo "Found the initialization-resource"
echo "${csv}" | jq -r '.metadata.annotations."operatorframework.io/initialization-resource"' | jq -r | tee "/tmp/default-dsc.json"
file="/tmp/default-dsc.json"
oc apply -f "${file}"

echo "⏳ Wait for DataScientCluster to be deployed"
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/${DSC_NAME} --timeout=9000s

# Verify RHOAI operator installation
timeout=400s

namespace="openshift-operators"
label_selectors=("control-plane=authorino-operator" "name=istio-operator")
authorino_channel=$(oc get subscription authorino-operator -n $namespace -o=jsonpath='{.spec.channel}{"\n"}')
if [[ "$authorino_channel" == "tech-preview-v1" ]]; then
  label_selectors+=("authorino-component=authorino-webhooks")
fi

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
label_selectors=("app=rhods-dashboard" "app=notebook-controller" "app.kubernetes.io/name=modelmesh-controller" "app.kubernetes.io/name=data-science-pipelines-operator" "control-plane=kserve-controller-manager" "app.kubernetes.io/part-of=model-registry-operator")
for label_selector in "${label_selectors[@]}"; do
  oc get deployment -l ${label_selector} -n ${namespace} -o json | jq -e '.status | .replicas == .readyReplicas'
done

# Verify all pods are running
oc_wait_for_pods() {
    local ns="${1}"
    local pods

    for _ in {1..60}; do
        echo "Waiting for pods in '${ns}' in state Running or Completed"
        pods=$(oc get pod -n "${ns}" | grep -v "Running\|Completed" | tail -n +2)
        echo "${pods}"
        if [[ -z "${pods}" ]]; then
            echo "All pods in '${ns}' are in state Running or Completed"
            break
        fi
        sleep 20
    done
    if [[ -n "${pods}" ]]; then
        echo "ERROR: Some pods in '${ns}' are not in state Running or Completed"
        echo "${pods}"
        exit 1
    fi
}
oc_wait_for_pods "redhat-ods-applications"

sleep 300
echo "OpenShfit AI Operator is deployed successfully"
