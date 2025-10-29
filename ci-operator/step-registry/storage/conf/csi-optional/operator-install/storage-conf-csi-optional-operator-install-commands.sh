#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

set -x

# This script automates the installation of any OLM operator on an OpenShift
# cluster using a generic OLMv1 ClusterExtension.
# It is configured via environment variables for easy use in CI/CD pipelines.

# --- Configuration via Environment Variables ---
# Required:
#   - OP_PACKAGE_NAME: The package name of the operator in OLM.
#   - OP_NAMESPACE:    The namespace where the operator will be installed.
#
# Optional:
#   - OP_CHANNEL:      The channel to subscribe to (defaults to 'stable').
#   - OP_SOURCE_NAME:  A custom CatalogSource 'ref' to use for the operator.
#   - OP_EXTENSION_NAME: The name for the ClusterExtension resource (defaults to package name).

# --- Read Environment Variables ---
PACKAGE_NAME="${OP_PACKAGE_NAME}"
TARGET_NAMESPACE="${OP_NAMESPACE}"
# CHANNEL="${OP_CHANNEL:-stable}" # Default to 'stable' if OP_CHANNEL is not set
SOURCE_NAME="${OP_SOURCE_NAME}"
EXTENSION_NAME="${OP_EXTENSION_NAME:-${OP_PACKAGE_NAME}}" # Default to package name
INDEX_IMAGE="${OP_INDEX_IMAGE}"

# --- Validate Required Variables ---
if [ -z "${PACKAGE_NAME}" ] || [ -z "${TARGET_NAMESPACE}" ]; then
    echo "❌ Error: Missing required environment variables."
    echo "   Please set OP_PACKAGE_NAME and OP_NAMESPACE."
    exit 1
fi

# --- Ensure Target Namespace Exists ---
if ! oc get namespace "${TARGET_NAMESPACE}" &>/dev/null; then
    echo "ℹ️  Namespace '${TARGET_NAMESPACE}' does not exist. Creating it..."
    if ! oc create namespace "${TARGET_NAMESPACE}"; then
        echo "❌ Error: Failed to create namespace '${TARGET_NAMESPACE}'."
        exit 1
    fi
    echo "✅ Namespace '${TARGET_NAMESPACE}' created successfully."
else
    echo "ℹ️  Namespace '${TARGET_NAMESPACE}' already exists."
fi

cat<<EOF | oc apply -f -
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  labels:
    olm.operatorframework.io/metadata.name: ${SOURCE_NAME}
  name: ${SOURCE_NAME}
spec:
  availabilityMode: Available
  priority: -300
  source:
    image:
      pollIntervalMinutes: 1
      ref: ${INDEX_IMAGE}
    type: Image
EOF

# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to apply the ClusterCatalog manifest."
    exit 1
fi

echo "✅ ClusterCatalog resource '${SOURCE_NAME}' applied."
echo "⌛ Waiting for the catalog to become healthy (max 10 minutes)..."

# --- Wait for Catalog to become READY ---
TIMEOUT_SECONDS=$((10 * 60)) # 10 minutes
INTERVAL_SECONDS=15
ELAPSED_SECONDS=0

while true; do
    # Check the state of the catalog connection.
    # The catalog is healthy when its lastObservedState is 'READY'.
    STATE=$(oc get clustercatalog "${SOURCE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Serving")].status}' 2>/dev/null)

    if [ "$STATE" == "True" ]; then
        echo "✅ Success! The ClusterCatalog '${SOURCE_NAME}' is healthy and ready."
        break
    fi

    # Check for timeout
    if [ ${ELAPSED_SECONDS} -ge ${TIMEOUT_SECONDS} ]; then
        echo "❌ Error: Timed out after 10 minutes waiting for ClusterCatalog to become ready."
        echo "   Current state is: '${STATE}'"
        echo "   Check the resource for more details: 'oc describe clustercatalog ${SOURCE_NAME}'"
        oc describe clustercatalog "${SOURCE_NAME}"
        exit 1
    fi

    echo "   - Catalog not yet ready (current state: '${STATE}'). Re-checking in ${INTERVAL_SECONDS}s..."
    sleep ${INTERVAL_SECONDS}
    ELAPSED_SECONDS=$((ELAPSED_SECONDS + INTERVAL_SECONDS))
done

cat<<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${PACKAGE_NAME}-installer
  namespace: ${TARGET_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${PACKAGE_NAME}-installer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: ${PACKAGE_NAME}-installer
  namespace: ${TARGET_NAMESPACE}
EOF

echo "✅ RBAC resources created successful."

# --- Dynamically Build Spec ---
SPEC_YAML="
  namespace: ${TARGET_NAMESPACE}
  serviceAccount:
    name: ${EXTENSION_NAME}-installer
  config:
    configType: Inline
    inline:
      watchNamespace: ${TARGET_NAMESPACE}
"
if [ -n "${SOURCE_NAME:-}" ]; then
  echo "ℹ️ Using custom CatalogSource ref: ${SOURCE_NAME}"
  SPEC_YAML="${SPEC_YAML}
  source:
    sourceType: Catalog
    catalog:
      packageName: ${PACKAGE_NAME}
    selector:
      matchLabels:
        olm.operatorframework.io/metadata.name: ${SOURCE_NAME}"
fi

# --- Create ClusterExtension ---
echo "▶️  Creating ClusterExtension to install the '${PACKAGE_NAME}' operator..."

echo "apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: ${EXTENSION_NAME}
spec: ${SPEC_YAML}"

cat <<EOF | oc apply -f -
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: ${EXTENSION_NAME}
spec: ${SPEC_YAML}
EOF

# shellcheck disable=SC2181
if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to apply the ClusterExtension manifest."
    exit 1
fi

echo "✅ ClusterExtension resource '${EXTENSION_NAME}' created."
echo "⌛ Waiting for the operator installation to complete..."

# --- Wait for Installation with Timeout ---
TIMEOUT_SECONDS=$((15 * 60)) # 15 minutes in seconds
INTERVAL_SECONDS=15
ELAPSED_SECONDS=0

while true; do
    # Check for success
    STATUS=$(oc get -n "${TARGET_NAMESPACE}" clusterextension "${EXTENSION_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null)
    if [ "$STATUS" == "True" ]; then
        echo "✅ Success! The '${PACKAGE_NAME}' operator has been installed successfully."
        oc get clusterextension.olm.operatorframework.io "${EXTENSION_NAME}"
        break
    fi
    
    # Check for explicit failure
    FAILED_STATUS=$(oc get -n "${TARGET_NAMESPACE}" clusterextension "${EXTENSION_NAME}" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null)
    if [ "$FAILED_STATUS" == "True" ]; then
        echo "❌ Error: Operator installation failed. Check the ClusterExtension status for details:"
        echo "   oc describe clusterextension ${EXTENSION_NAME}"
        oc describe clusterextension "${EXTENSION_NAME}"
        exit 1
    fi

    # Check for timeout
    if [ ${ELAPSED_SECONDS} -ge ${TIMEOUT_SECONDS} ]; then
        echo "❌ Error: Timed out after 15 minutes waiting for operator to install."
        echo "   Check the ClusterExtension status for details:"
        echo "   oc describe -n ${TARGET_NAMESPACE} clusterextension ${EXTENSION_NAME}"
        oc describe -n "${TARGET_NAMESPACE}" clusterextension "${EXTENSION_NAME}"
        exit 1
    fi

    echo "   - Installation in progress. Waited ${ELAPSED_SECONDS}s. Re-checking in ${INTERVAL_SECONDS}s..."
    sleep ${INTERVAL_SECONDS}
    ELAPSED_SECONDS=$((ELAPSED_SECONDS + INTERVAL_SECONDS))
done

echo "🎉 Installation complete."