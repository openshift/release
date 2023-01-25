#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ -z "${VOLSYNC_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${VOLSYNC_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${VOLSYNC_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

if [[ "${VOLSYNC_TARGET_NAMESPACES}" == "!install" ]]; then
  VOLSYNC_TARGET_NAMESPACES="${VOLSYNC_INSTALL_NAMESPACE}"
fi

echo "Installing ${VOLSYNC_PACKAGE} from ${VOLSYNC_CHANNEL} into ${VOLSYNC_INSTALL_NAMESPACE}, targeting ${VOLSYNC_TARGET_NAMESPACES}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${VOLSYNC_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${VOLSYNC_INSTALL_NAMESPACE}-operator-group"
  namespace: "${VOLSYNC_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${VOLSYNC_TARGET_NAMESPACES}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${VOLSYNC_PACKAGE}"
  namespace: "${VOLSYNC_INSTALL_NAMESPACE}"
spec:
  channel: "${VOLSYNC_CHANNEL}"
  installPlanApproval: Automatic
  name: "${VOLSYNC_PACKAGE}"
  source: "${VOLSYNC_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 120

echo "oc get csv --all-namespaces"
oc get csv --all-namespaces

echo "oc get subscriptions"
oc get subscriptions --all-namespaces

echo "get operators"
oc get operators --all-namespaces
