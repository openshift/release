#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Exercise VM create, start, stop, and delete lifecycle using shared storage and emit JUnit for each phase.
# Inputs: FA__CNV__TEST_NAMESPACE, FA__CNV__SHARED_STORAGE_CLASS, FA__CNV__VM_NAME, FA__CNV__VM_MEMORY_REQUEST, FA__CNV__VM_CPU_REQUEST, ARTIFACT_DIR (step ref env for FA__CNV__*).
# Non-obvious: JUnit helpers EscapeXml and RecordTest wrap VM API operations.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_vm_lifecycle_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=""
typeset -i testStart=0
typeset testStatus=''
typeset testMessage=''
typeset vmStatus=''
typeset pvcStatus=''

# Function to escape XML special characters
function EscapeXml () {
  typeset text="${1}"; (($#)) && shift
  printf '%s' "${text}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'

  true
}

# Function to add test result to JUnit XML
function AddTestResult () {
  typeset -n totalRef="${1}"; (($#)) && shift
  typeset -n failedRef="${1}"; (($#)) && shift
  typeset -n casesRef="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-VMLifecycleTests}"; (($#)) && shift

  typeset escapedName=''
  escapedName="$(EscapeXml "${testName}")"
  typeset escapedMessage=''
  escapedMessage="$(EscapeXml "${testMessage}")"
  typeset escapedClassName=''
  escapedClassName="$(EscapeXml "${testClassName}")"

  totalRef=$((totalRef + 1))

  if [[ "${testStatus}" == "passed" ]]; then
    casesRef="${casesRef}
    <testcase name=\"${escapedName}\" classname=\"${escapedClassName}\" time=\"${testDuration}\"/>"
  else
    failedRef=$((failedRef + 1))
    casesRef="${casesRef}
    <testcase name=\"${escapedName}\" classname=\"${escapedClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${escapedMessage}</failure>
    </testcase>"
  fi

  true
}

# Function to generate JUnit XML report
function GenerateJunitXml () {
  typeset -i totalDuration=0
  totalDuration=$((SECONDS - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="VM Lifecycle Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_vm_lifecycle_tests.xml"
  fi

  true
}

# Helper function to record test result (eliminates repetitive duration calculation)
function RecordTest () {
  typeset totalName="${1}"; (($#)) && shift
  typeset failedName="${1}"; (($#)) && shift
  typeset casesName="${1}"; (($#)) && shift
  typeset testStart="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift

  typeset -i testDuration=0
  testDuration=$((SECONDS - testStart))
  AddTestResult "${totalName}" "${failedName}" "${casesName}" "${testName}" "${testStatus}" "${testDuration}" "${testMessage}"

  true
}

# Trap to ensure JUnit XML is generated even on failure
trap '{( GenerateJunitXml; true )}' EXIT

# Create test namespace
if ! oc get namespace "${FA__CNV__TEST_NAMESPACE}"; then
  oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
  if ! oc wait "namespace/${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=300s; then
    oc get namespace "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
fi

# Check if shared storage class exists
if ! oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}"; then
  oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o yaml --ignore-not-found
  exit 1
fi

# Create DataVolume for VM
if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg name "${FA__CNV__VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" \
    '.metadata.name = ($name + "-dv") | .metadata.namespace = $ns | .spec.pvc.storageClassName = $sc' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -; then
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
  # Wait for DataVolume to be ready
  if ! oc wait datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    oc get datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
else
  oc get datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

# Create VM with shared storage
if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg name "${FA__CNV__VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg mem "${FA__CNV__VM_MEMORY_REQUEST}" \
    --arg cpu "${FA__CNV__VM_CPU_REQUEST}" \
    '.metadata.name = $name | .metadata.namespace = $ns | .spec.template.metadata.labels["kubevirt.io/vm"] = $name | .spec.template.spec.domain.resources.requests.memory = $mem | .spec.template.spec.domain.resources.requests.cpu = $cpu | .spec.template.spec.volumes[1].persistentVolumeClaim.claimName = ($name + "-dv")' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -; then
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: placeholder-vm
  namespace: placeholder-ns
  labels:
    app: lifecycle-test
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
            memory: placeholder-mem
            cpu: placeholder-cpu
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
          claimName: placeholder-claim
YAML
  # Wait for VM to be created
  if ! oc wait "vm/${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=60s; then
    oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
else
  oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

# Test 1: Start VM
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  # Wait for VMI to be running
  if oc wait "vmi/${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s; then
    testStatus="passed"
  else
    testMessage="VMI not running within 5m timeout"
    oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to patch VM spec.running=true"
  oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
fi

RecordTest "testsTotal" "testsFailed" "testCases" "${testStart}" "fa_cnv_1011_prerequisite_start_vm" "${testStatus}" "${testMessage}"

# If VM didn't start, we can't continue with remaining tests
if [[ "${testStatus}" != "passed" ]]; then
  exit 1
fi

# Test 2: FA-CNV-1011 - Stop VM
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
  # Wait for VMI to be deleted
  typeset isVmiDeleted=false
  if oc wait "vmi/${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=delete --timeout=300s; then
    isVmiDeleted=true
  fi

  if [[ "${isVmiDeleted}" == "true" ]]; then
    if ! vmStatus="$(oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}')"; then
      testMessage="Failed to get VM status after VMI deletion"
      oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    elif [[ "${vmStatus}" == "Stopped" ]]; then
      testStatus="passed"
    else
      testMessage="VM status not 'Stopped' after VMI deletion (status: ${vmStatus})"
    fi
  else
    testMessage="VMI not deleted within 5m timeout"
    oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to patch VM spec.running=false"
  oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
fi

RecordTest "testsTotal" "testsFailed" "testCases" "${testStart}" "fa_cnv_1011_stop_vm_with_shared_storage" "${testStatus}" "${testMessage}"

# Test 3: FA-CNV-1012 - Restart VM
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  # Wait for VMI to be running after restart
  if oc wait "vmi/${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=300s; then
    if ! pvcStatus="$(oc get pvc "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')"; then
      testMessage="Failed to get PVC status after VM restart"
      oc get pvc "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    elif [[ "${pvcStatus}" == "Bound" ]]; then
      testStatus="passed"
    else
      testMessage="PVC not bound after VM restart (status: ${pvcStatus})"
    fi
  else
    testMessage="VMI not running within 5m timeout after restart"
    oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to patch VM spec.running=true for restart"
  oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
fi

RecordTest "testsTotal" "testsFailed" "testCases" "${testStart}" "fa_cnv_1012_restart_vm_with_shared_storage" "${testStatus}" "${testMessage}"

# Cleanup
if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
  if ! oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    true
  fi
fi
oc delete vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

true
