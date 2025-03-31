#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CLUSTER_ID=$(< "${SHARED_DIR}/cluster-id")
NAMESPACE_RHOAI="redhat-ods-applications"
NAMESPACE_OPERATOR="openshift-operators"
NAMESPACE_SERVERLESS="openshift-serverless"
TIMEOUT="400s"

OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
OCM_VERSION=$(ocm version)
echo "Logging into stage with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "https://api.stage.openshift.com" --token "${OCM_TOKEN}"

# Modify Upgrade policy
NEXT_UPGRADE_RUN=""
if [[ "${UPDATE_APPROVAL}" == "manual" ]]; then
  NEXT_UPGRADE_RUN=', "next_run": "2040-01-01T00:00:00Z"'
fi

cat > upgrade_policy.json <<EOF
{
  "addon_id": "managed-odh",
  "cluster_id": "${CLUSTER_ID}",
  "schedule_type": "${UPDATE_APPROVAL}",
  "version": "${RHOAI_VERSION}"${NEXT_UPGRADE_RUN}
}
EOF

ocm post "/api/addons_mgmt/v1/clusters/${CLUSTER_ID}/upgrade_plans" --body upgrade_policy.json

# Install RHOAI Addon
cat > rhoai_addon.json <<EOF
{
  "addon": {
    "id": "managed-odh"
  },
  "addon_version": {
    "id": "${RHOAI_VERSION}"
  },
  "parameters": {
    "items": []
  }
}
EOF

ocm post "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/addons" --body rhoai_addon.json

# Wait for Operator Workloads
echo "Wait for Operator Pods to be Ready"
LABEL_SELECTORS_OPERATOR=("control-plane=authorino-operator" "authorino-component=authorino-webhooks" "name=istio-operator")
for selector in "${LABEL_SELECTORS_OPERATOR[@]}"; do
  oc wait --for=condition=ready pod -l "${selector}" -n "${NAMESPACE_OPERATOR}" --timeout="${TIMEOUT}"
done

LABEL_SELECTORS_SERVERLESS=("name=knative-openshift" "name=knative-openshift-ingress" "name=knative-operator")
for selector in "${LABEL_SELECTORS_SERVERLESS[@]}"; do
  oc wait --for=condition=ready pod -l "${selector}" -n "${NAMESPACE_SERVERLESS}" --timeout="${TIMEOUT}"
done

echo "Wait for Deployment Replicas to be Ready"
LABEL_SELECTORS_RHOAI=(
  "app=rhods-dashboard"
  "app=notebook-controller"
  "app.kubernetes.io/name=modelmesh-controller"
  "app.kubernetes.io/name=data-science-pipelines-operator"
  "control-plane=kserve-controller-manager"
  "app.kubernetes.io/part-of=model-registry-operator"
)

for selector in "${LABEL_SELECTORS_RHOAI[@]}"; do
  oc get deployment -l "${selector}" -n "${NAMESPACE_RHOAI}" -o json | jq -e '.status | .replicas == .readyReplicas'
done

oc_wait_for_pods() {
  local ns="${1}"
  for _ in {1..60}; do
    echo "Waiting for pods in '${ns}' to be Running or Completed"
    local pods
    pods=$(oc get pod -n "${ns}" | grep -Ev "Running|Completed" | tail -n +2 || true)
    if [[ -z "${pods}" ]]; then
      echo "All pods in '${ns}' are Running or Completed"
      return
    fi
    echo "${pods}"
    sleep 20
  done
  echo "ERROR: Some pods in '${ns}' are not in Running or Completed state"
  echo "${pods}"
  exit 1
}

oc_wait_for_pods "${NAMESPACE_RHOAI}"


echo "OpenShift AI addon is installed successfully"
