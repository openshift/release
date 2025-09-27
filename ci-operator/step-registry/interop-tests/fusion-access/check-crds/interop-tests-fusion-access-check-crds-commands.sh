#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"

echo "🔍 Checking IBM Storage Scale CRD availability..."

echo "Waiting for IBM Storage Scale CRDs to be available..."
echo "Note: FusionAccess operator should install IBM Storage Scale operator and its CRDs"

# Check if FusionAccess operator is actually installing the IBM Storage Scale operator
echo "Checking for IBM Storage Scale operator installation..."
sleep 30  # Give the operator time to start installing

# Wait for CRDs with longer timeout and better error handling
if oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s 2>/dev/null; then
  echo "✅ IBM Storage Scale CRDs are available"
else
  echo "⚠️  IBM Storage Scale CRDs not found after 10 minutes"
  echo "This may indicate that the FusionAccess operator is not installing the IBM Storage Scale operator"
  echo "Checking for any IBM Storage Scale related operators..."
  oc get csv -A | grep -i spectrum || echo "No IBM Spectrum Scale operators found"
  echo "Checking for any IBM Storage Scale related CRDs..."
  oc get crd | grep -i spectrum || echo "No IBM Spectrum Scale CRDs found"
  echo "Checking FusionAccess operator logs for errors..."
  oc logs -n ${FUSION_ACCESS_NAMESPACE} -l app.kubernetes.io/name=openshift-fusion-access-operator --tail=50 || echo "Cannot get FusionAccess operator logs"
  echo "Proceeding anyway - the Cluster creation may still work if CRDs are installed later"
fi

echo "Verifying CRD details..."
if oc get crd clusters.scale.spectrum.ibm.com >/dev/null 2>&1; then
  oc get crd clusters.scale.spectrum.ibm.com -o yaml | grep -A 5 -B 5 "validation\|schema" || echo "No validation schema found in CRD"
else
  echo "⚠️  CRD clusters.scale.spectrum.ibm.com not found"
fi

echo "Checking for any CRD-related events..."
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -i "clusters.scale.spectrum.ibm.com" | tail -5 || echo "No CRD-related events found"

echo "✅ IBM Storage Scale CRD availability check completed!"
