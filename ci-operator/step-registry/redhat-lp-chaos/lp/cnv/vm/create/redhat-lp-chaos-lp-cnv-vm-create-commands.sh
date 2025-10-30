#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

declare vmList=""
declare vmNamesForWait=""

: '--- Target Configuration Summary ---'
: "VM_NUM: ${VM_REPLICA_COUNT} | InstanceType: ${VM_INSTANCE_TYPE}"
: "Source: ${DV_SOURCE_NAME} (NS: ${DV_SOURCE_NS})"
: '------------------------------------'

: "--- 0. Install yq & jq if needed ---"
yum install -y jq >/dev/null 2>&1 && \
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq >/dev/null 2>&1 && \
chmod +x /usr/local/bin/yq >/dev/null 2>&1

: "--- 1. Creating namespace ${VM_NAMESPACE} ---"
# Use 'oc new-project' to ensure namespace exists or is created
{
    oc create namespace "${VM_NAMESPACE}" \
        --dry-run=client -o yaml --save-config
} | oc apply -f -

: '--- 2. Create virtualmachine ---'
function vm_create() {
  declare vmIndex="${1}"; (($#)) && shift
  declare currentVmName="${VM_NAME_PREFIX}-${vmIndex}"
  : "Submitting target VirtualMachine ${currentVmName}"
  # The DataVolume is automatically created via dataVolumeTemplates
  {
    oc create -f- --dry-run=client -o yaml --save-config |
    yq -o json eval . | \
    jq -c \
        --arg vmName "${currentVmName}" \
        --arg vmNamespace "${VM_NAMESPACE}" \
        --arg instanceType "${VM_INSTANCE_TYPE}" \
        --arg dvSourceName "${DV_SOURCE_NAME}" \
        --arg dvSourceNs "${DV_SOURCE_NS}" \
        --arg vmPreference "${VM_PREFERENCE}" \
        '
        # 1. Replace metadata (name, namespace)
        .metadata.name = $vmName |
        .metadata.namespace = $vmNamespace |
        .spec.template.metadata.labels.special = $vmName |

        # 2. Replace spec fields
        .spec.instancetype.name = $instanceType |
        .spec.preference.name = $vmPreference |

        # 3. Replace Volumes and DataVolumeTemplates
        .spec.dataVolumeTemplates[0].metadata.name = ($vmName + "-volume") |
        .spec.dataVolumeTemplates[0].spec.sourceRef.name = $dvSourceName |
        .spec.dataVolumeTemplates[0].spec.sourceRef.namespace = $dvSourceNs |

        # 4. Replace VM Template Volumes reference
        .spec.template.spec.volumes[0].dataVolume.name = ($vmName + "-volume")
        ' | \
    yq -p json -o yaml eval .
  } 0<<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ""
  namespace: ""
spec:
  # Dynamic DataVolume Template: Triggers PVC creation and image cloning
  dataVolumeTemplates:
    - metadata:
        name: ""
      spec:
        sourceRef:
          kind: DataSource
          name: ""
          namespace: ""
        storage: {}
  # InstanceType and Preference replace manual CPU/Memory configuration
  instancetype:
    name: ""
  preference:
    name: ""
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
            name: ""
          name: rootdisk
EOF

  true
}

: '--- 3. Main execution logic ---'
for ((i=1; i<=${VM_REPLICA_COUNT}; i++)); do
    : "=== Start to create the ${i} vm (Total: ${VM_REPLICA_COUNT})"
    vm_create "${i}"
    vmList+="${VM_NAME_PREFIX}-${i} "
    vmNamesForWait+="vm/${VM_NAME_PREFIX}-${i} "
done
  : 'Waiting for VMs to enter Ready state...'
  # This single wait command ensures both DV cloning AND VM startup are complete.
  oc wait ${vmNamesForWait} -n "${VM_NAMESPACE}" --for=condition=Ready --timeout="${VM_WAIT_TIMEOUT}"

: '--- 4. Passing variables to subsequent steps (SHARED_DIR) ---'
# Prow mechanism: write VM name and namespace to SHARED_DIR
echo "${vmList}" > "${SHARED_DIR}/target-vm-name.txt"

true