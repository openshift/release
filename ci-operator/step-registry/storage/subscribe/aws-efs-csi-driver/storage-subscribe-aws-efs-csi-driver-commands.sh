#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ROLE_ARN_FILE="${SHARED_DIR}/efs-csi-driver-operator-role-arn"
if [[ ! -f "${ROLE_ARN_FILE}" ]]; then
  echo "ERROR: ${ROLE_ARN_FILE} not found. Run storage-create-csi-aws-efs-sts-operator-role first."
  exit 1
fi
ROLE_ARN=$(cat "${ROLE_ARN_FILE}")
echo "Using IRSA role ARN: ${ROLE_ARN}"

PACKAGE="aws-efs-csi-driver-operator"

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${SUB_INSTALL_NAMESPACE}"
EOF

# Only create OperatorGroup if one does not already exist
OG_COUNT=$(oc get operatorgroup -n "${SUB_INSTALL_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [[ "${OG_COUNT}" -eq 0 ]]; then
  echo "No OperatorGroup found in ${SUB_INSTALL_NAMESPACE}, creating one"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${SUB_INSTALL_NAMESPACE}-operator-group"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec: {}
EOF
else
  echo "OperatorGroup already exists in ${SUB_INSTALL_NAMESPACE}, skipping creation"
fi

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${PACKAGE}"
  namespace: "${SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${PACKAGE}"
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
    env:
    - name: ROLEARN
      value: "${ROLE_ARN}"
EOF

echo "Subscription created, waiting 60s for OLM to resolve..."
sleep 60

RETRIES=30
echo "Waiting up to ~16m for ${PACKAGE} CSV to reach Succeeded phase (${RETRIES} retries x 30s)..."
CSV=""
for i in $(seq "${RETRIES}"); do
  if [[ -z "${CSV}" ]]; then
    CSV=$(oc get subscription -n "${SUB_INSTALL_NAMESPACE}" "${PACKAGE}" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  fi

  if [[ -z "${CSV}" ]]; then
    echo "Try ${i}/${RETRIES}: installedCSV not set yet, retrying in 30s"
    sleep 30
    continue
  fi

  PHASE=$(oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)

  if [[ "${PHASE}" == "Succeeded" ]]; then
    echo "${PACKAGE} deployed successfully (${CSV})"
    exit 0
  fi

  echo "Try ${i}/${RETRIES}: ${CSV} phase=${PHASE:-unknown}, retrying in 30s"
  sleep 30
done

echo "Error: Failed to deploy ${PACKAGE}"
oc get csv -n "${SUB_INSTALL_NAMESPACE}" "${CSV:-<no-csv>}" -o yaml 2>/dev/null || true
oc describe subscription -n "${SUB_INSTALL_NAMESPACE}" "${PACKAGE}" 2>/dev/null || true
exit 1
