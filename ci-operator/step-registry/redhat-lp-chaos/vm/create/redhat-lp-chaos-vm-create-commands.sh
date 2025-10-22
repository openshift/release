#!/bin/bash

set -euxo pipefail # Enables debug mode (-x) and strict mode (-e, -u, -o pipefail)

# ----------------------------------------------------
# 0. VARIABLE DEFINITIONS
# ----------------------------------------------------
VM_REPLICA_COUNT="${VM_REPLICA_COUNT:-2}"
VM_NAME_PREFIX="${VM_NAME_PREFIX:-cnv-chaos-vm}"
VM_NAMESPACE="${VM_NAMESPACE:-cnv-chaos-test-ns}"
VM_INSTANCE_TYPE="${VM_INSTANCE_TYPE:-u1.medium}"
VM_PREFERENCE="${VM_PREFERENCE:-rhel.9}"
DV_SOURCE_NAME="${DV_SOURCE_NAME:-rhel9}"
DV_SOURCE_NS="${DV_SOURCE_NS:-openshift-virtualization-os-images}"


echo "--- Target Configuration Summary ---"
echo "VM_NUM: $VM_REPLICA_COUNT | InstanceType: $VM_INSTANCE_TYPE"
echo "Source: $DV_SOURCE_NAME (NS: $DV_SOURCE_NS)"
echo "------------------------------------"

# ----------------------------------------------------
# 1. Create Namespace
# ----------------------------------------------------
echo "--- Creating namespace $VM_NAMESPACE ---"
# Use 'oc new-project' to ensure namespace exists or is created
oc new-project "$VM_NAMESPACE" || true

# ----------------------------------------------------
# 2. Create VirtualMachine
# ----------------------------------------------------
function vm_create() {
  local INDEX=$1
  local CURRENT_VM_NAME="${VM_NAME_PREFIX}-${INDEX}"
  echo "Creating target VirtualMachine $CURRENT_VM_NAME"
  # The DataVolume is automatically created via dataVolumeTemplates
  oc apply -f- <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $CURRENT_VM_NAME
  namespace: $VM_NAMESPACE
spec:
  # Dynamic DataVolume Template
  dataVolumeTemplates:
    - metadata:
        name: $CURRENT_VM_NAME-volume
      spec:
        sourceRef:
          kind: DataSource
          name: $DV_SOURCE_NAME
          namespace: $DV_SOURCE_NS
        storage: {}
  # InstanceType and Preference replace manual CPU/Memory configuration
  instancetype:
    name: $VM_INSTANCE_TYPE
  preference:
    name: $VM_PREFERENCE
  runStrategy: Always # Start immediately
  template:
    metadata:
      labels:
        app: chaos-target
    spec:
      domain:
        devices:
          interfaces:
            - masquerade: {}
              name: default
      networks:
        - name: default
          pod: {}
      volumes:
        - dataVolume:
            name: $CURRENT_VM_NAME-volume
          name: rootdisk
EOF

  echo "VM $CURRENT_VM_NAME creating ..."
}

# ----------------------------------------------------
# 3. MAIN EXECUTION LOGIC
# ----------------------------------------------------
VM_LIST=""

for ((i=1; i<=$VM_REPLICA_COUNT; i++)); do
    echo "=== Start to create the $i vm (Total: $VM_REPLICA_COUNT)"
    vm_create $i
    VM_LIST+="${VM_NAME_PREFIX}-${i} "
    VM_NAMES_FOR_WAIT+="vm/${VM_NAME_PREFIX}-${i} "
done
  echo "Waiting for VMs to enter Ready state (Max 15 minutes)..."
  # This single wait command ensures both DV cloning AND VM startup are complete.
  oc wait $VM_NAMES_FOR_WAIT -n $VM_NAMESPACE --for=condition=Ready --timeout=15m

echo "--- 4. Passing variables to subsequent steps (SHARED_DIR) ---"
# Prow mechanism: write VM name and namespace to SHARED_DIR
mkdir -p "${SHARED_DIR}"
echo "$VM_LIST" > "${SHARED_DIR}/target_vm_name.txt"
echo "$VM_NAMESPACE" > "${SHARED_DIR}/target_vm_namespace.txt"

echo "VM creation process completed."