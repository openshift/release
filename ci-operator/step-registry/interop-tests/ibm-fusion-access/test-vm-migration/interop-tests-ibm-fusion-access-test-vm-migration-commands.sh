#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Validate VM migration between workers when at least two workers exist; prints diagnostic tables and records JUnit results.
# Inputs: FA__CNV__TEST_NAMESPACE, FA__CNV__SHARED_STORAGE_CLASS, FA__CNV__VM_NAME, FA__CNV__VM_MEMORY_REQUEST, FA__CNV__VM_CPU_REQUEST, FA__CNV__VM_MIGRATION_TIMEOUT, ARTIFACT_DIR, MAP_TESTS.
# Non-obvious: Exits early with skipped tests when fewer than two worker nodes are available.

: "${FA__CNV__VM_MIGRATION_TIMEOUT:=10m}"

typeset junitResultsFile="${ARTIFACT_DIR}/junit_vm_migration_tests.xml"
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
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-VMMigrationTests}"; (($#)) && shift

  testName="$(EscapeXml "${testName}")"
  testMessage="$(EscapeXml "${testMessage}")"
  testClassName="$(EscapeXml "${testClassName}")"

  ((++testsTotal))

  if [[ "${testStatus}" == "passed" ]]; then
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    ((++testsFailed))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi

  true
}

function GenerateJunitXml () {
  typeset totalDuration=$((SECONDS - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="VM Migration Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_vm_migration_tests.xml"
  fi

  true
}

function RecordTest () {
  typeset testStart="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift

  typeset testDuration=$((SECONDS - testStart))
  AddTestResult "${testName}" "${testStatus}" "${testDuration}" "${testMessage}"

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

if ! oc get namespace "${FA__CNV__TEST_NAMESPACE}"; then
  oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
  if ! oc wait "namespace/${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=300s; then
    oc get namespace "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
fi

if ! oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}"; then
  oc get storageclass -o yaml --ignore-not-found
  exit 1
fi

typeset testStart=''
typeset testStatus=''
typeset testMessage=''

testStart="${SECONDS}"
testStatus="failed"

typeset nodesJson=''
nodesJson="$(oc get nodes -l node-role.kubernetes.io/worker= -o json)"
typeset -i workerCount=0
workerCount="$(printf '%s' "${nodesJson}" | jq '.items | length')"

if [[ "${workerCount}" -lt 2 ]]; then
  testMessage="Insufficient worker nodes for migration (need 2+, found ${workerCount})"
  RecordTest "${testStart}" "fa_cnv_1022_prepare_migration_environment" "${testStatus}" "${testMessage}"

  exit 0
fi

testStatus="passed"
RecordTest "${testStart}" "fa_cnv_1022_prepare_migration_environment" "${testStatus}" "${testMessage}"

{
  printf 'NAME\tSTATUS\tROLE\n'
  printf '%s' "${nodesJson}" | jq -r '.items[] | "\(.metadata.name)\t\(.status.conditions // [] | .[] | select(.type=="Ready") | .status)\t\(.metadata.labels["node-role.kubernetes.io/worker"] // "")"'
} | column -t -s $'\t'

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg name "${FA__CNV__VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" \
    '.metadata.name = ($name + "-dv") | .metadata.namespace = $ns | .spec.pvc.storageClassName = $sc' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: placeholder-dv
  namespace: placeholder
spec:
  source:
    registry:
      url: "docker://quay.io/kubevirt/fedora-cloud-container-disk-demo:latest"
  pvc:
    accessModes:
    - ReadWriteMany
    resources:
      requests:
        storage: 5Gi
    storageClassName: placeholder
YAML
then
  if ! oc wait datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    oc get datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi
else
  exit 1
fi

typeset sourceNode=''

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg name "${FA__CNV__VM_NAME}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg mem "${FA__CNV__VM_MEMORY_REQUEST}" \
    --arg cpu "${FA__CNV__VM_CPU_REQUEST}" \
    '.metadata.name = $name | .metadata.namespace = $ns | .spec.template.metadata.labels["kubevirt.io/vm"] = $name | .spec.template.spec.domain.resources.requests.memory = $mem | .spec.template.spec.domain.resources.requests.cpu = $cpu | .spec.template.spec.volumes |= (map(if .name == "disk1" then .persistentVolumeClaim.claimName |= ($name + "-dv") else . end))' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: placeholder
  namespace: placeholder
  labels:
    app: migration-test
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: placeholder
    spec:
      domain:
        resources:
          requests:
            memory: placeholder
            cpu: placeholder
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
  if oc wait --for=jsonpath='{.status.phase}'=Running \
      "vmi/${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
    sourceNode="$(oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}')"
  else
    oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
    exit 1
  fi
else
  exit 1
fi

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

typeset migrationName=''
migrationName="${FA__CNV__VM_NAME}-migration-$(date +%s)"

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg name "${migrationName}" \
    --arg ns "${FA__CNV__TEST_NAMESPACE}" \
    --arg vmi "${FA__CNV__VM_NAME}" \
    '.metadata.name = $name | .metadata.namespace = $ns | .spec.vmiName = $vmi' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: placeholder
  namespace: placeholder
spec:
  vmiName: placeholder
YAML
then
  if oc wait vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${FA__CNV__VM_MIGRATION_TIMEOUT}"; then
    testStatus="passed"
  else
    testMessage="Migration did not complete within ${FA__CNV__VM_MIGRATION_TIMEOUT}"

    oc get vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to create VirtualMachineInstanceMigration resource"
fi

RecordTest "${testStart}" "fa_cnv_1023_execute_vm_live_migration" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

typeset targetNode=''
typeset vmiJson=''
if ! vmiJson="$(oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o json)"; then
  testMessage="VMI not found after migration"
  vmiJson=''
fi
if [[ -n "${vmiJson}" ]]; then
  targetNode="$(printf '%s' "${vmiJson}" | jq -r '.status.nodeName // empty')"
fi

if [[ -n "${targetNode}" ]] && [[ "${sourceNode}" != "${targetNode}" ]]; then
  typeset vmiPhase=''
  vmiPhase="$(printf '%s' "${vmiJson}" | jq -r '.status.phase // empty')"

  if [[ "${vmiPhase}" == "Running" ]]; then
    typeset pvcStatus=''
    pvcStatus="$(oc get pvc "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')"

    if [[ "${pvcStatus}" == "Bound" ]]; then
      typeset vmStatus=''
      vmStatus="$(oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}')"

      if [[ "${vmStatus}" == "Running" ]]; then
        testStatus="passed"
      else
        testMessage="VM status not 'Running' after migration (status: ${vmStatus})"
      fi
    else
      testMessage="PVC not bound after migration (status: ${pvcStatus})"
    fi
  else
    testMessage="VMI not running after migration (phase: ${vmiPhase})"
    oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  if [[ -n "${targetNode}" ]]; then
    testMessage="VM stayed on same node (${sourceNode})"
  fi
fi

RecordTest "${testStart}" "fa_cnv_1024_verify_migration_results" "${testStatus}" "${testMessage}"

typeset vmimJson=''
if vmimJson="$(oc get vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" -o json)"; then
  {
    printf 'NAME\tPHASE\tSTART\n'
    printf '%s' "${vmimJson}" | jq -r '"\(.metadata.name)\t\(.status.phase // "")\t\(.metadata.creationTimestamp // "")"'
  } | column -t -s $'\t'
fi

if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
  if ! oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    true
  fi
fi
oc delete vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

true
