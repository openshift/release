#!/bin/bash
set -euo pipefail

# For disconnected environments, source proxy config if available
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "=== Overriding cluster-etcd-operator image ==="
echo "Custom image: ${ETCD_OPERATOR_IMAGE}"
echo "Wait time: ${OVERRIDE_WAIT_TIME}s"

# Record the original image for comparison
ORIGINAL_IMAGE=$(oc get deployment -n openshift-etcd-operator etcd-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Original image: ${ORIGINAL_IMAGE}"

# Step 1: Mark the etcd-operator deployment as unmanaged in CVO
echo "--- Marking etcd-operator as unmanaged in ClusterVersion spec.overrides ---"
oc patch clusterversion version --type=merge -p '{
  "spec": {
    "overrides": [{
      "kind": "Deployment",
      "name": "etcd-operator",
      "namespace": "openshift-etcd-operator",
      "unmanaged": true,
      "group": "apps/v1"
    }]
  }
}'

# Step 2: Patch the etcd-operator deployment with the custom image
echo "--- Patching etcd-operator deployment with custom image ---"
oc set image -n openshift-etcd-operator deployment/etcd-operator \
  etcd-operator="${ETCD_OPERATOR_IMAGE}"
oc set env -n openshift-etcd-operator deployment/etcd-operator \
  OPERATOR_IMAGE="${ETCD_OPERATOR_IMAGE}" \
  IMAGE="${ETCD_OPERATOR_IMAGE}"

# Step 3: Wait for the deployment to roll out
echo "--- Waiting for etcd-operator deployment rollout ---"
oc rollout status deployment/etcd-operator -n openshift-etcd-operator --timeout=120s

# Confirm the new image is running
CURRENT_IMAGE=$(oc get deployment -n openshift-etcd-operator etcd-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Current image after patch: ${CURRENT_IMAGE}"

if [[ "${CURRENT_IMAGE}" != "${ETCD_OPERATOR_IMAGE}" ]]; then
  echo "ERROR: Image was not updated. Expected ${ETCD_OPERATOR_IMAGE}, got ${CURRENT_IMAGE}"
  exit 1
fi

# Step 4: Wait the configured period
echo "--- Waiting ${OVERRIDE_WAIT_TIME}s to verify no reconciliation ---"
sleep "${OVERRIDE_WAIT_TIME}"

# Step 5: Verify the image was not reconciled back
FINAL_IMAGE=$(oc get deployment -n openshift-etcd-operator etcd-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Image after ${OVERRIDE_WAIT_TIME}s wait: ${FINAL_IMAGE}"

if [[ "${FINAL_IMAGE}" != "${ETCD_OPERATOR_IMAGE}" ]]; then
  echo "FAIL: Image was reconciled back!"
  echo "  Expected: ${ETCD_OPERATOR_IMAGE}"
  echo "  Got:      ${FINAL_IMAGE}"
  exit 1
fi

echo "SUCCESS: Custom etcd-operator image persisted after ${OVERRIDE_WAIT_TIME}s"
echo "  Image: ${FINAL_IMAGE}"
