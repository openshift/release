#!/bin/bash

set -uo pipefail

function on_failure() {
  echo "============================================"
  echo "DEBUG: collect-validation-results failed"
  echo "Sleeping 6 hours for live cluster investigation"
  echo "Cluster API: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
  echo "============================================"
  sleep 21600
}
trap 'on_failure' ERR

set -e

echo "=== Reading saved state from SHARED_DIR ==="
if [[ ! -f "${SHARED_DIR}/validation-timestamp" ]] || [[ ! -f "${SHARED_DIR}/validation-image" ]]; then
  echo "WARNING: validation-timestamp or validation-image not found in SHARED_DIR"
  echo "The run-validation-checkup step may not have run or completed"
  exit 0
fi

TIMESTAMP=$(cat "${SHARED_DIR}/validation-timestamp")
OCP_VIRT_VALIDATION_IMAGE=$(cat "${SHARED_DIR}/validation-image")
echo "TIMESTAMP: ${TIMESTAMP}"
echo "Image: ${OCP_VIRT_VALIDATION_IMAGE}"

echo "=== Deploying pvc-reader via get_results ==="
MANIFESTS_FILE=$(mktemp)
trap 'rm -f "${MANIFESTS_FILE}"' EXIT

oc run validation-get-results -n ocp-virt-validation --restart=Never \
  --image="${OCP_VIRT_VALIDATION_IMAGE}" \
  --overrides='{"spec":{"serviceAccountName":"ocp-virt-validation-sa"}}' \
  --env="TIMESTAMP=${TIMESTAMP}" \
  --command -- get_results 2>/dev/null

oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/validation-get-results -n ocp-virt-validation --timeout=5m

oc logs validation-get-results -n ocp-virt-validation | awk '/^---$/{found=1} found{print}' > "${MANIFESTS_FILE}"
oc delete pod validation-get-results -n ocp-virt-validation --force --grace-period=0 2>/dev/null || true

echo "Generated $(grep -c '^kind:' "${MANIFESTS_FILE}") manifests"
oc apply -f "${MANIFESTS_FILE}"

echo "=== Waiting for pvc-reader pod ==="
PVC_READER_POD=$(oc get pods -n ocp-virt-validation -l app=pvc-reader \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "${PVC_READER_POD}" ]]; then
  echo "WARNING: No pvc-reader pod found"
  exit 0
fi
oc wait --for=condition=ready --timeout=5m "pod/${PVC_READER_POD}" -n ocp-virt-validation

echo "=== Copying results from pvc-reader pod ==="
RESULTS_DIR="${ARTIFACT_DIR}/validation-results"
mkdir -p "${RESULTS_DIR}"
oc exec -n ocp-virt-validation "${PVC_READER_POD}" -- \
  tar cf - --exclude='lost+found' -C /results . 2>/dev/null | tar xf - -C "${RESULTS_DIR}/" || \
  echo "WARNING: Failed to copy results from pvc-reader pod"

echo "=== Copying JUnit XMLs to ARTIFACT_DIR ==="
JUNIT_FILES=$(find "${RESULTS_DIR}" -type f \( -name "junit*.xml" -o -name "*junit*.xml" \) 2>/dev/null || true)
JUNIT_COUNT=0

if [[ -n "${JUNIT_FILES}" ]]; then
  while IFS= read -r junit_file; do
    if [[ -f "${junit_file}" ]]; then
      BASENAME=$(basename "${junit_file}")
      PARENT_DIR=$(basename "$(dirname "${junit_file}")")
      DEST_FILE="${ARTIFACT_DIR}/${PARENT_DIR}_${BASENAME}"
      cp "${junit_file}" "${DEST_FILE}"
      JUNIT_COUNT=$((JUNIT_COUNT + 1))
      echo "  Copied: ${junit_file} -> $(basename "${DEST_FILE}")"
    fi
  done <<< "${JUNIT_FILES}"
  echo "Total JUnit files copied: ${JUNIT_COUNT}"
else
  echo "WARNING: No JUnit files found in ${RESULTS_DIR}"
fi

echo "=== Artifact collection complete ==="
