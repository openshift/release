#!/bin/bash

set -euxo pipefail # Enables debug mode (-x) and strict mode (-e, -u, -o pipefail)

: "--- Target Configuration Summary ---"
: "VM_NUM: ${VM_REPLICA_COUNT} | InstanceType: ${VM_INSTANCE_TYPE}"
: "Source: ${DV_SOURCE_NAME} (NS: ${DV_SOURCE_NS})"
: "------------------------------------"


# ----------------------------------------------------
# 0. Install yq & jq if needed
# ----------------------------------------------------
#curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
#yum install -y jq

# ----------------------------------------------------
# 1. Create Namespace
# ----------------------------------------------------
: "--- Creating namespace ${VM_NAMESPACE} ---"
# Use 'oc new-project' to ensure namespace exists or is created
{
    oc create namespace "${VM_NAMESPACE}" \
        --dry-run=client -o yaml --save-config
} | oc apply -f -
: "Namespace ${VM_NAMESPACE} created or verified successfully."

# ----------------------------------------------------
# 2. Create VirtualMachine
# ----------------------------------------------------
function vm_create() {
  typeset vmIndex="${1}"; (($#)) && shift
  local currentVmName="${VM_NAME_PREFIX}-${vmIndex}"
  : "Submitting target VirtualMachine ${currentVmName}"
  # The DataVolume is automatically created via dataVolumeTemplates
  {
    oc create -f- --dry-run=client -o yaml --save-config
  } 0<<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${currentVmName}
  namespace: ${VM_NAMESPACE}
spec:
  # Dynamic DataVolume Template: Triggers PVC creation and image cloning
  dataVolumeTemplates:
    - metadata:
        name: ${currentVmName}-volume
      spec:
        sourceRef:
          kind: DataSource
          name: ${DV_SOURCE_NAME}
          namespace: ${DV_SOURCE_NS}
        storage: {}
  # InstanceType and Preference replace manual CPU/Memory configuration
  instancetype:
    name: ${VM_INSTANCE_TYPE}
  preference:
    name: ${VM_PREFERENCE}
  runStrategy: Always
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
        # References the dynamically created DataVolume
        - dataVolume:
            name: ${currentVmName}-volume
          name: rootdisk
EOF

  : "VM ${currentVmName} submitted for creation."
}

# ----------------------------------------------------
# 3. MAIN EXECUTION LOGIC
# ----------------------------------------------------
VM_LIST=""

for ((i=1; i<=${VM_REPLICA_COUNT}; i++)); do
    : "=== Start to create the ${i} vm (Total: ${VM_REPLICA_COUNT})"
    vm_create "${i}"
    VM_LIST+="${VM_NAME_PREFIX}-${i} "
    VM_NAMES_FOR_WAIT+="vm/${VM_NAME_PREFIX}-${i} "
done
  : "Waiting for VMs to enter Ready state (Max 15 minutes)..."
  # This single wait command ensures both DV cloning AND VM startup are complete.
  oc wait ${VM_NAMES_FOR_WAIT} -n ${VM_NAMESPACE} --for=condition=Ready --timeout=15m

: "--- 4. Passing variables to subsequent steps (SHARED_DIR) ---"
# Prow mechanism: write VM name and namespace to SHARED_DIR
mkdir -p "${SHARED_DIR}"
echo "${VM_LIST}" > "${SHARED_DIR}/target_vm_name.txt"
echo "${VM_NAMESPACE}" > "${SHARED_DIR}/target_vm_namespace.txt"

: "VM creation process completed."