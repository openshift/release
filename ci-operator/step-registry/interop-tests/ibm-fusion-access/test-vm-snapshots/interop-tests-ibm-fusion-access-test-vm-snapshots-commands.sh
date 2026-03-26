#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Create a VM, take VolumeSnapshots, restore, and verify data using FA__CNV__* snapshot settings; emit JUnit.
# Inputs: FA__CNV__TEST_NAMESPACE, FA__CNV__SHARED_STORAGE_CLASS, FA__CNV__VM_NAME, snapshot or restore name envs, timeouts, ARTIFACT_DIR, MAP_TESTS.
# Non-obvious: May ensure a VolumeSnapshotClass exists before snapshot operations.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_vm_snapshots_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=''

function EscapeXml () {
  typeset text="${1}"; (($#)) && shift
  printf '%s' "${text}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'

  true
}

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset -i testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-VMSnapshotsTests}"; (($#)) && shift

  typeset escapedName=''
  escapedName="$(EscapeXml "${testName}")"
  typeset escapedMessage=''
  escapedMessage="$(EscapeXml "${testMessage}")"
  typeset escapedClassName=''
  escapedClassName="$(EscapeXml "${testClassName}")"

  ((++testsTotal))

  if [[ "${testStatus}" == "passed" ]]; then
    testCases="${testCases}
    <testcase name=\"${escapedName}\" classname=\"${escapedClassName}\" time=\"${testDuration}\"/>"
  else
    ((++testsFailed))
    testCases="${testCases}
    <testcase name=\"${escapedName}\" classname=\"${escapedClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${escapedMessage}</failure>
    </testcase>"
  fi

  true
}

function GenerateJunitXml () {
  typeset -i totalDuration=$((SECONDS - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="VM Snapshots Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  if [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_vm_snapshots_tests.xml"
  fi

  true
}

function RecordTest () {
  typeset -i testStart="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift

  typeset -i testDuration=$((SECONDS - testStart))
  AddTestResult "${testName}" "${testStatus}" "${testDuration}" "${testMessage}"

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
if ! oc wait "namespace/${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=300s; then
  oc get namespace "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}"

typeset -i snapshotClasses=0
snapshotClasses=$(
  oc get volumesnapshotclass \
    -o jsonpath-as-json='{.items[*].metadata.name}' |
  jq 'length'
)

if [[ "${snapshotClasses}" -eq 0 ]]; then
  if ! (
    {
      oc create -f - --dry-run=client -o json --save-config |
      yq -p json -o yaml eval . |
      oc apply -f -
    } 0<<'YAML'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ibm-spectrum-scale-snapshotclass
driver: spectrumscale.csi.ibm.com
deletionPolicy: Delete
YAML
  ); then
    oc get volumesnapshotclass -o yaml --ignore-not-found
    true
  fi
else
  oc get volumesnapshotclass -o custom-columns="NAME:.metadata.name,DRIVER:.driver,DELETIONPOLICY:.deletionPolicy"
fi

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg vmName "${FA__CNV__VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" \
    '.metadata.name = ($vmName + "-dv") | .metadata.namespace = $ns | .spec.pvc.storageClassName = $sc' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: placeholder-dv
  namespace: placeholder-ns
spec:
  source:
    registry:
      url: "docker://quay.io/kubevirt/fedora-cloud-container-disk-demo:latest"
  pvc:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
    storageClassName: placeholder-sc
YAML
then
  if ! oc wait datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    oc get datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
else
  oc get datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg vmName "${FA__CNV__VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg mem "${FA__CNV__VM_MEMORY_REQUEST}" \
    --arg cpu "${FA__CNV__VM_CPU_REQUEST}" \
    '.metadata.name = $vmName | .metadata.namespace = $ns | .spec.template.metadata.labels["kubevirt.io/vm"] = $vmName | .spec.template.spec.domain.resources.requests.memory = $mem | .spec.template.spec.domain.resources.requests.cpu = $cpu | .spec.template.spec.volumes[1].persistentVolumeClaim.claimName = ($vmName + "-dv")' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: placeholder-vm
  namespace: placeholder-ns
  labels:
    app: snapshot-test
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/vm: placeholder-vm
    spec:
      domain:
        resources:
          requests:
            memory: 1Gi
            cpu: "1"
        devices:
          disks:
          - name: disk0
            disk:
              bus: virtio
          - name: disk1
            disk:
              bus: virtio
      volumes:
      - name: disk0
        containerDisk:
          image: quay.io/kubevirt/fedora-cloud-container-disk-demo:latest
      - name: disk1
        persistentVolumeClaim:
          claimName: placeholder-dv
YAML
then
  if ! oc wait "vm/${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=60s; then
    oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
else
  oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

typeset -i testStart="${SECONDS}"
typeset testStatus='failed'
typeset testMessage=''

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg snapName "${FA__CNV__SNAPSHOT_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg vmName "${FA__CNV__VM_NAME}" \
    '.metadata.name = $snapName | .metadata.namespace = $ns | .spec.source.name = $vmName' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: placeholder-snap
  namespace: placeholder-ns
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: placeholder-vm
YAML
then
  if oc wait vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout="${FA__CNV__VM_SNAPSHOT_TIMEOUT}"; then
    testStatus="passed"
  else
    testMessage="Snapshot not ready within ${FA__CNV__VM_SNAPSHOT_TIMEOUT}"
    oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  testMessage="Failed to create VirtualMachineSnapshot resource"
fi

RecordTest "${testStart}" "fa_cnv_1025_create_vm_snapshot" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus='failed'
testMessage=''

typeset vmSnapshotJson=''
if vmSnapshotJson="$(oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o json)"; then
  typeset volumeSnapshotJson=''
  volumeSnapshotJson="$(oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" -o json)"
  typeset -i volumeSnapshots=0
  volumeSnapshots=$(printf '%s' "${volumeSnapshotJson}" | jq '.items | length')

  if [[ "${volumeSnapshots}" -gt 0 ]]; then
    printf '%s' "${volumeSnapshotJson}" | jq -r '
      (["NAME", "READYTOUSE", "SOURCEPVC"] | @tsv),
      (.items[] | [.metadata.name, ((.status.readyToUse // "N/A") | tostring), (.spec.source.persistentVolumeClaimName // "N/A")] | @tsv)
    '
    typeset snapshotContent=''
    snapshotContent="$(printf '%s' "${vmSnapshotJson}" | jq -r '.status.virtualMachineSnapshotContentName // empty')"
    if [[ -n "${snapshotContent}" ]]; then
      testStatus="passed"
    else
      testMessage="Snapshot content manifest not found"
    fi
  else
    testMessage="No VolumeSnapshot resources created"
  fi
else
  testMessage="VirtualMachineSnapshot resource not found"
fi

RecordTest "${testStart}" "fa_cnv_1026_verify_vm_snapshot_exists" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus='failed'
testMessage=''

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg restoreName "${FA__CNV__RESTORE_VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg snapName "${FA__CNV__SNAPSHOT_NAME}" \
    '.metadata.name = ($restoreName + "-restore") | .metadata.namespace = $ns | .spec.target.name = $restoreName | .spec.virtualMachineSnapshotName = $snapName' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineRestore
metadata:
  name: placeholder-restore
  namespace: placeholder-ns
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: placeholder-vm
  virtualMachineSnapshotName: placeholder-snap
YAML
then
  if oc wait vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout="${FA__CNV__VM_SNAPSHOT_TIMEOUT}"; then
    if oc get vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      if oc patch vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
        typeset isVmiFound=false
        if oc wait "vmi/${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=120s; then
          isVmiFound=true
        else
          oc get vmi "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
          if ! oc describe vmi "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
            true
          fi
        fi

        if [[ "${isVmiFound}" == "true" ]]; then
          testStatus="passed"
        else
          testMessage="Restored VM VMI not created within timeout"
        fi
      else
        testMessage="Failed to start restored VM"
      fi
    else
      testMessage="Restored VM not found after restore operation"
    fi
  else
    testMessage="Restore not complete within ${FA__CNV__VM_SNAPSHOT_TIMEOUT}"
    oc get vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  oc get vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  testMessage="Failed to create VirtualMachineRestore resource"
fi

RecordTest "${testStart}" "fa_cnv_1027_restore_vm_from_snapshot" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus='failed'
testMessage=''

if oc delete vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
  typeset isSnapshotDeleted=false
  if oc wait "vmsnapshot/${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=delete --timeout=120s; then
    isSnapshotDeleted=true
  fi

  if [[ "${isSnapshotDeleted}" == "true" ]]; then
    if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      testStatus="passed"
    else
      testMessage="Original VM not found after snapshot deletion"
    fi
  else
    testMessage="Snapshot not deleted within 2m timeout"
    oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  fi
else
  testMessage="Failed to delete VirtualMachineSnapshot resource"
fi

RecordTest "${testStart}" "fa_cnv_1028_delete_vm_snapshot" "${testStatus}" "${testMessage}"

if ! oc get vmsnapshot -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,READYTOUSE:.status.readyToUse,AGE:.metadata.creationTimestamp"; then
  true
fi

if ! oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,READYTOUSE:.status.readyToUse,SOURCEPVC:.spec.source.persistentVolumeClaimName"; then
  true
fi

if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
  if ! oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    true
  fi
fi
if oc get vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
  if ! oc patch vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    true
  fi
fi
oc delete vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete vmi "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete vmsnapshot -n "${FA__CNV__TEST_NAMESPACE}" --all --ignore-not-found

oc delete vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

true
