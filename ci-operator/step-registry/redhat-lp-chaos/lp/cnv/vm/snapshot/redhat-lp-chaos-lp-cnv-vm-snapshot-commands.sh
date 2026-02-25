#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

if [[ ! -f "${SHARED_DIR}/target-vm-name.txt" ]]; then
    echo "FATAL ERROR: target-vm-name.txt not found. VM create step must have failed."
    exit 1
fi

VM_LIST=$(cat "${SHARED_DIR}/target-vm-name.txt")
VM_NAMESPACE="${LPC_LP_CNV__VM__NAMESPACE}"
TIMEOUT_MIN=10

echo "--- Starting Snapshot Creation ---"
echo "Target Namespace: ${VM_NAMESPACE}"
echo "Target VMs: ${VM_LIST}"
echo "----------------------------------"

for VM_NAME in ${VM_LIST}; do
    if [[ -z "${VM_NAME}" ]]; then continue; fi

    SNAPSHOT_NAME="${LPC_LP_CNV__SNAPSHOT_NAME}-${VM_NAME}-$(date +%s)"

    echo ">> Processing VM: '${VM_NAME}' with snapshot '${SNAPSHOT_NAME}'"

    # Ensure the VM is in a state that allows snapshotting (Running)
    echo "Waiting for VMI '${VM_NAME}' to be in 'Running' phase..."
    wait_time=0
    while [[ "$(oc get vmi "${VM_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.phase}')" != "Running" ]]; do
      if (( wait_time > TIMEOUT_MIN * 60 )); then
        echo "ERROR: Timeout waiting for VMI '${VM_NAME}' to become Running before snapshotting."
        oc get vmi "${VM_NAME}" -n "${VM_NAMESPACE}" -o yaml
        exit 1
      fi
      echo "VMI is not Running yet, waiting... (${wait_time}s)"
      sleep 30
      wait_time=$((wait_time + 30))
    done
    echo "VMI '${VM_NAME}' is Running. Proceeding with snapshot."

    # Create the VirtualMachineSnapshot object
    cat <<EOF | oc apply -f -
apiVersion: snapshot.kubevirt.io/v1alpha1
kind: VirtualMachineSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${VM_NAMESPACE}
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${VM_NAME}
EOF

    # Wait for the snapshot to become ReadyToUse
    echo "Waiting for snapshot '${SNAPSHOT_NAME}' to be ready..."
    wait_time=0
    while [[ "$(oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.readyToUse}')" != "true" ]]; do
      if (( wait_time > TIMEOUT_MIN * 60 )); then
        echo "ERROR: Timeout waiting for snapshot '${SNAPSHOT_NAME}' to become ready."
        oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${VM_NAMESPACE}" -o yaml
        exit 1
      fi

      phase=$(oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [[ "$phase" == "Failed" ]]; then
          echo "ERROR: Snapshot creation failed with Phase: Failed!"
          oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${VM_NAMESPACE}" -o yaml
          exit 1
      fi

      echo "Snapshot not ready yet, waiting... (Phase: $phase, ${wait_time}s)"
      sleep 15
      wait_time=$((wait_time + 15))
    done

    echo "SUCCESS: Snapshot '${SNAPSHOT_NAME}' for VM '${VM_NAME}' was created and is ready to use."
done

true