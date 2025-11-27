#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

declare vmList=""
declare vmNamesForWait=""

: '--- Target Configuration Summary ---'
: "VM_NUM: ${LPC_LP_CNV__VM__REPLICA_COUNT} | InstanceType: ${LPC_LP_CNV__VM__INSTANCE_TYPE}"
: "Source: ${LPC_LP_CNV__VM__DV_SOURCE_NAME} (NS: ${LPC_LP_CNV__VM__DV_SOURCE_NS})"
: '------------------------------------'

# Create namespace
{
    oc create namespace "${LPC_LP_CNV__VM__NS}" \
        --dry-run=client -o yaml --save-config
} | oc apply -f -

# Create vms
function VmCreate() {
  declare vmIndex="${1}"; (($#)) && shift
  declare currentVmName="${LPC_LP_CNV__VM__PREFIX}-${vmIndex}"
  : "Submitting target VirtualMachine ${currentVmName}"
  # The DataVolume is automatically created via dataVolumeTemplates
  {
    oc create -f- --dry-run=client -o json --save-config |
    jq -c \
        --arg vmName "${currentVmName}" \
        --arg vmNamespace "${LPC_LP_CNV__VM__NS}" \
        --arg instanceType "${LPC_LP_CNV__VM__INSTANCE_TYPE}" \
        --arg dvSourceName "${LPC_LP_CNV__VM__DV_SOURCE_NAME}" \
        --arg dvSourceNs "${LPC_LP_CNV__VM__DV_SOURCE_NS}" \
        --arg vmPreference "${LPC_LP_CNV__VM__PREFERENCE}" \
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


for ((i=1; i<=${LPC_LP_CNV__VM__REPLICA_COUNT}; i++)); do
    : "=== Start to create the ${i} vm (Total: ${LPC_LP_CNV__VM__REPLICA_COUNT})"
    VmCreate "${i}"
    vmList+="${LPC_LP_CNV__VM__PREFIX}-${i} "
    vmNamesForWait+="vm/${LPC_LP_CNV__VM__PREFIX}-${i} "
done
  : 'Waiting for VMs to enter Ready state...'
  oc wait ${vmNamesForWait} -n "${LPC_LP_CNV__VM__NS}" --for=condition=Ready --timeout="${LPC_LP_CNV__VM__WAIT_TIMEOUT}"

echo "${vmList}" > "${SHARED_DIR}/target-vm-name.txt"

true