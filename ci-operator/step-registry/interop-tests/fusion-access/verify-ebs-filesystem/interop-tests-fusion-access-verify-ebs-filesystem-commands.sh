#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"

echo "🔍 Verifying IBM Storage Scale Filesystem..."

# Verify filesystem exists and get status
oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE}

# Check filesystem conditions
echo "Filesystem conditions:"
oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} \
  -o jsonpath='{range .status.conditions[*]}  {.type}: {.status} - {.message}{"\n"}{end}'

# Verify StorageClass was created
echo ""
if oc get storageclass | grep -q spectrum; then
  echo "✅ StorageClass created:"
  oc get storageclass | grep spectrum
else
  echo "⚠️  StorageClass not found yet (may still be creating)"
fi

echo ""
echo "✅ Filesystem verification completed"
