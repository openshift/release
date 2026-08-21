#!/usr/bin/env bash
set -euo pipefail

echo "=== TEMPORARY: Verify cleanup-infrastructure image has required binaries ==="
echo "This step will be removed after validation."
echo ""

failed=0
for cmd in jq gcloud curl; do
  if command -v "${cmd}" &>/dev/null; then
    echo "✓ ${cmd}: $(command -v ${cmd})"
  else
    echo "✗ ${cmd}: NOT FOUND"
    failed=1
  fi
done

# Check kubectl or oc
if command -v kubectl &>/dev/null; then
  echo "✓ kubectl: $(command -v kubectl)"
elif command -v oc &>/dev/null; then
  echo "✓ oc (kubectl substitute): $(command -v oc)"
else
  echo "✗ kubectl/oc: NEITHER FOUND"
  failed=1
fi

echo ""
if [[ ${failed} -eq 1 ]]; then
  echo "FAIL: Missing required binaries. Choose a different image."
  exit 1
fi

echo "PASS: All required binaries present."
echo ""
echo "Versions:"
jq --version 2>/dev/null || true
gcloud version 2>/dev/null | head -3 || true
kubectl version --client 2>/dev/null | head -1 || oc version --client 2>/dev/null | head -1 || true
