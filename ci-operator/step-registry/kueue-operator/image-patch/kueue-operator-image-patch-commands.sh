#!/usr/bin/env bash
set -euxo pipefail

if [[ "$JOB_TYPE" == *"periodic"* ]]; then
    echo "Skipping step due to JOB_TYPE matching $JOB_TYPE"
    exit 0
fi

source "${SHARED_DIR}/env"
echo "Using Operator Image: ${OPERATOR_IMAGE}"
echo "Using Operand Image: ${OPERAND_IMAGE}"
echo "Using Must-Gather Image: ${MUST_GATHER_IMAGE}"
echo "Using Bundle Image: ${BUNDLE_IMAGE}"

CSV=$(oc get csv -n openshift-kueue-operator -o jsonpath='{.items[0].metadata.name}')
oc patch csv -n openshift-kueue-operator "${CSV}" --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"$OPERATOR_IMAGE\"}]"

# Patch the operand image in the RELATED_IMAGE_OPERAND_IMAGE environment variable
echo "Patching operand image reference in CSV..."
CONTAINER_INDEX=0
ENV_INDEX=$(oc get csv -n openshift-kueue-operator "${CSV}" -o json | jq ".spec.install.spec.deployments[0].spec.template.spec.containers[${CONTAINER_INDEX}].env | map(.name == \"RELATED_IMAGE_OPERAND_IMAGE\") | index(true)")

if [[ "$ENV_INDEX" != "null" ]]; then
  oc patch csv -n openshift-kueue-operator "${CSV}" --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/${CONTAINER_INDEX}/env/${ENV_INDEX}/value\", \"value\": \"$OPERAND_IMAGE\"}]"
  echo "Successfully patched operand image to: ${OPERAND_IMAGE}"
else
  echo "WARNING: RELATED_IMAGE_OPERAND_IMAGE environment variable not found in CSV"
fi

# Patch the must-gather image in the RELATED_IMAGE_MUST_GATHER_IMAGE environment variable
echo "Patching must-gather image reference in CSV..."
ENV_INDEX=$(oc get csv -n openshift-kueue-operator "${CSV}" -o json | jq ".spec.install.spec.deployments[0].spec.template.spec.containers[${CONTAINER_INDEX}].env | map(.name == \"RELATED_IMAGE_MUST_GATHER_IMAGE\") | index(true)")

if [[ "$ENV_INDEX" != "null" ]]; then
  oc patch csv -n openshift-kueue-operator "${CSV}" --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/${CONTAINER_INDEX}/env/${ENV_INDEX}/value\", \"value\": \"$MUST_GATHER_IMAGE\"}]"
  echo "Successfully patched must-gather image to: ${MUST_GATHER_IMAGE}"
else
  echo "WARNING: RELATED_IMAGE_MUST_GATHER_IMAGE environment variable not found in CSV"
fi