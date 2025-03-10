#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# TODO: 1. fetch CLUSTER_ID from OCM
# CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id") ?

# TODO: 2. add rhoai_addon.json content for OCM post
#{
#  "addon": {
#    "id": "managed-odh"
#},
#  "addon_version": {
#    "id": ${RHOAI_VERSION}
#},
#  "parameters": {
#        "items": []  --> TODO: check how updateApproval label is controlled
#    }
#}

# TODO: 2. post addon config body with OCM
# ocm post /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/addons --body rhoai_addon.json

# Verify RHOAI operator installation
namespace="openshift-operators"
timeout=400s
label_selectors=("control-plane=authorino-operator" "authorino-component=authorino-webhooks" "name=istio-operator")
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
echo "OpenShfit AI addon is installed successfully"
