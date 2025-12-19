#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Auto-detect namespace based on cluster version if not explicitly set
if [[ -z "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
  MINOR_VERSION=$(echo $CLUSTER_VERSION | cut -d. -f2)

  echo "Detected OpenShift version: ${CLUSTER_VERSION}"

  # For OpenShift 4.20+, use openshift-lvm-storage, otherwise use openshift-storage
  if [[ ${MINOR_VERSION} -ge 20 ]]; then
    LVM_OPERATOR_SUB_INSTALL_NAMESPACE="openshift-lvm-storage"
  else
    LVM_OPERATOR_SUB_INSTALL_NAMESPACE="openshift-storage"
  fi

  echo "Auto-detected namespace: ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
else
  echo "Using explicitly set namespace: ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi

if [[ -z "${LVM_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${LVM_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ -n "$MULTISTAGE_PARAM_OVERRIDE_LVM_OPERATOR_SUB_CHANNEL" ]]; then
    LVM_OPERATOR_SUB_CHANNEL="$MULTISTAGE_PARAM_OVERRIDE_LVM_OPERATOR_SUB_CHANNEL"
fi
echo "$LVM_OPERATOR_SUB_CHANNEL"

if [[ "${LVM_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  LVM_SUB_TARGET_NAMESPACES="${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${LVM_OPERATOR_SUB_PACKAGE} from channel: ${LVM_OPERATOR_SUB_CHANNEL} in source: ${LVM_OPERATOR_SUB_SOURCE} into ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${LVM_SUB_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${LVM_OPERATOR_SUB_PACKAGE}"
  namespace: "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${LVM_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${LVM_OPERATOR_SUB_PACKAGE}"
  source: "${LVM_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" "${LVM_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n ${LVM_OPERATOR_SUB_INSTALL_NAMESPACE} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${LVM_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${LVM_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${LVM_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${LVM_OPERATOR_SUB_PACKAGE}"
