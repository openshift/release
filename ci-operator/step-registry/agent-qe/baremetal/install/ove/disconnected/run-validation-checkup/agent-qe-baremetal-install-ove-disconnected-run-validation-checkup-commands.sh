#!/bin/bash

set -euo pipefail

echo "=== Setting ODF StorageClass as default ==="
oc patch storageclass "${STORAGE_CLASS}" \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
echo "StorageClass ${STORAGE_CLASS} set as default"

echo "=== Discovering validation image from CNV CSV ==="
CSV_NAME=$(oc get csv -n "${TARGET_NAMESPACE}" -o json | \
  jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).metadata.name')
if [[ -z "${CSV_NAME}" ]]; then
  echo "ERROR: Could not find kubevirt-hyperconverged CSV in ${TARGET_NAMESPACE}"
  exit 1
fi
echo "Found CSV: ${CSV_NAME}"

OCP_VIRT_VALIDATION_IMAGE=$(oc get csv -n "${TARGET_NAMESPACE}" "${CSV_NAME}" -o json | \
  jq -r '.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image')
if [[ -z "${OCP_VIRT_VALIDATION_IMAGE}" ]]; then
  echo "ERROR: Could not find ocp-virt-validation-checkup image in CSV ${CSV_NAME}"
  exit 1
fi
echo "Validation image: ${OCP_VIRT_VALIDATION_IMAGE}"

echo "=== Generating and applying validation checkup manifests ==="
oc create namespace ocp-virt-validation 2>/dev/null || true

MANIFESTS_FILE=$(mktemp)
trap 'rm -f "${MANIFESTS_FILE}"' EXIT

oc run validation-generate -n ocp-virt-validation --restart=Never \
  --image="${OCP_VIRT_VALIDATION_IMAGE}" \
  --env="OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE}" \
  --env="STORAGE_CLASS=${STORAGE_CLASS}" \
  --env="TEST_SKIPS=${TEST_SKIPS}" \
  --env="DRY_RUN=${DRY_RUN}" \
  --command -- generate 2>/dev/null

oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/validation-generate -n ocp-virt-validation --timeout=5m

oc logs validation-generate -n ocp-virt-validation | awk '/^---$/{found=1} found{print}' > "${MANIFESTS_FILE}"
oc delete pod validation-generate -n ocp-virt-validation --force --grace-period=0 2>/dev/null || true

echo "Generated $(grep -c '^kind:' "${MANIFESTS_FILE}") manifests"

for ATTEMPT in 1 2 3; do
  echo "=== Applying manifests (attempt ${ATTEMPT}) ==="
  oc apply -f "${MANIFESTS_FILE}"

  echo "Waiting for validation pod to start..."
  sleep 15
  MOUNT_FAILED=$(oc get events -n ocp-virt-validation --field-selector reason=FailedMount \
    -o jsonpath='{.items[0].message}' 2>/dev/null || echo "")
  if [[ -z "${MOUNT_FAILED}" ]]; then
    echo "Pod started successfully"
    break
  fi

  echo "WARNING: Volume mount failed (attempt ${ATTEMPT}): ${MOUNT_FAILED}"
  if [[ ${ATTEMPT} -lt 3 ]]; then
    echo "Cleaning up for retry..."
    oc delete job -n ocp-virt-validation -l app=ocp-virt-validation --force --grace-period=0 2>/dev/null || true
    JOB_PVC=$(grep -A2 'kind: PersistentVolumeClaim' "${MANIFESTS_FILE}" | grep 'name:' | awk '{print $2}')
    oc delete pvc "${JOB_PVC}" -n ocp-virt-validation 2>/dev/null || true
    oc delete events -n ocp-virt-validation --field-selector reason=FailedMount 2>/dev/null || true
    sleep 10
  fi
done

echo "Creating PodDisruptionBudget to protect validation pod from eviction..."
cat <<'PDBEOF' | oc apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ocp-virt-validation-pdb
  namespace: ocp-virt-validation
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: ocp-virt-validation
PDBEOF

echo "=== Waiting for validation Job to complete (timeout: ${OCP_VIRT_VALIDATION_TIMEOUT}) ==="
TIMEOUT_MINUTES="${OCP_VIRT_VALIDATION_TIMEOUT%m}"
TIMEOUT_SECS=$((TIMEOUT_MINUTES * 60))
DEADLINE=$((SECONDS + TIMEOUT_SECS))
JOB_STATUS=""

while [[ ${SECONDS} -lt ${DEADLINE} ]]; do
  IS_COMPLETE=$(oc get job -n ocp-virt-validation -l app=ocp-virt-validation \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
  IS_FAILED=$(oc get job -n ocp-virt-validation -l app=ocp-virt-validation \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  if [[ "${IS_COMPLETE}" == "True" ]]; then
    JOB_STATUS="Complete"
    echo "Job reached terminal state: ${JOB_STATUS}"
    break
  elif [[ "${IS_FAILED}" == "True" ]]; then
    JOB_STATUS="Failed"
    echo "Job reached terminal state: ${JOB_STATUS}"
    break
  fi
  sleep 30
done

if [[ "${JOB_STATUS}" != "Complete" ]]; then
  echo "=== Collecting diagnostic info (status: ${JOB_STATUS:-timeout}) ==="
  echo "Job status:"
  oc get job -n ocp-virt-validation -l app=ocp-virt-validation -o yaml || true
  echo "Pod status:"
  oc get pods -n ocp-virt-validation -l app=ocp-virt-validation -o yaml || true
  echo "Events (sorted by time):"
  oc get events -n ocp-virt-validation --sort-by=.lastTimestamp || true
  echo "Pod logs (last 50 lines):"
  oc logs -n ocp-virt-validation -l app=ocp-virt-validation --tail=50 || true
fi

echo "=== Extracting TIMESTAMP from Job ==="
TIMESTAMP=$(oc -n ocp-virt-validation get job --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].spec.template.spec.containers[?(@.name=="ocp-virt-validation-checkup")].env[?(@.name=="TIMESTAMP")].value}')
if [[ -z "${TIMESTAMP}" ]]; then
  echo "ERROR: Could not extract TIMESTAMP from Job"
  exit 1
fi
echo "TIMESTAMP: ${TIMESTAMP}"

echo "${TIMESTAMP}" > "${SHARED_DIR}/validation-timestamp"
echo "${OCP_VIRT_VALIDATION_IMAGE}" > "${SHARED_DIR}/validation-image"

echo "=== Checking validation results ==="
RESULTS=$(oc get configmap "ocp-virt-validation-${TIMESTAMP}" -n ocp-virt-validation \
  -o jsonpath='{.data.self-validation-results}' 2>/dev/null || echo "")
if [[ -z "${RESULTS}" ]]; then
  echo "WARNING: Could not retrieve results ConfigMap"
  echo "Job may have failed before producing results"
  exit 1
fi

echo "Results summary:"
echo "${RESULTS}" | head -20

FAILED=$(echo "${RESULTS}" | grep -oE 'failed:[[:space:]]*[0-9]+' | grep -v 'failed:[[:space:]]*0' || true)
if [[ -n "${FAILED}" ]]; then
  echo "ERROR: Validation checkup has failed tests: ${FAILED}"
  exit 1
fi

echo "=== All validation tests passed ==="
