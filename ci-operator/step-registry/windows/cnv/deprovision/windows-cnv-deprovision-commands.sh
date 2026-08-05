#!/bin/bash
set -o nounset
set -o pipefail
# Do not set -o errexit: cleanup steps should continue on individual failures

echo "=== Windows CNV Deprovision: Cleaning up KubeVirt Windows VMs ==="

VM_NAMESPACE="default"
OS_IMAGES_NAMESPACE="openshift-virtualization-os-images"

# Delete VMs identified by marker files
for f in "${SHARED_DIR}"/*_cnv_vm.txt; do
  if [[ -f "${f}" ]]; then
    vm_name=$(basename "${f}" "_cnv_vm.txt")
    echo "$(date -u --rfc-3339=seconds) - Deleting VM ${vm_name}..."
    oc delete vm "${vm_name}" -n "${VM_NAMESPACE}" --wait=false 2>/dev/null || true

    echo "$(date -u --rfc-3339=seconds) - Deleting sysprep Secret ${vm_name}-unattend..."
    oc delete secret "${vm_name}-unattend" -n "${VM_NAMESPACE}" --wait=false 2>/dev/null || true

    echo "$(date -u --rfc-3339=seconds) - Deleting DataVolume ${vm_name}-volume..."
    oc delete datavolume "${vm_name}-volume" -n "${VM_NAMESPACE}" --wait=false 2>/dev/null || true

    rm -f "${f}"
  fi
done

# Delete headless Service
echo "$(date -u --rfc-3339=seconds) - Deleting headless Service..."
oc delete service headless -n "${VM_NAMESPACE}" --wait=false 2>/dev/null || true

# Delete imported golden image DataVolumes and registry auth Secret (best-effort)
for dv_name in win2k25-ci win2k22-ci; do
  oc delete datavolume "${dv_name}" -n "${OS_IMAGES_NAMESPACE}" --wait=false 2>/dev/null || true
done
oc delete secret openshift-cnv-containerdisks-auth -n "${OS_IMAGES_NAMESPACE}" --wait=false 2>/dev/null || true

# Delete WMCO resources (best-effort, may already be cleaned by tests)
echo "$(date -u --rfc-3339=seconds) - Cleaning up WMCO resources (best-effort)..."
oc delete configmap windows-instances \
  -n openshift-windows-machine-config-operator --wait=false 2>/dev/null || true
oc delete secret cloud-private-key \
  -n openshift-windows-machine-config-operator --wait=false 2>/dev/null || true

echo "=== Windows CNV Deprovision Complete ==="
