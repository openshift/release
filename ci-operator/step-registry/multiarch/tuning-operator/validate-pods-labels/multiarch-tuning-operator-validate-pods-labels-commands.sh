#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

trap 'FRC=$?; createMTOJunit' EXIT TERM

# Generate the Junit for MTO
function createMTOJunit() {
    if (( FRC == 0 )); then
        cat <<EOF >"${ARTIFACT_DIR}/import-MTO.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="mto perfscale test" tests="1" failures="0">
  <testcase name="mto perfscale test should succeed">
    <system-out>
      <![CDATA[
The total pods number is ${total_pods}
Pods with "multiarch.openshift.io/scheduling-gate=removed" label are ${pods_with_scheduling_gate_removed}
Pods without "multiarch.openshift.io/scheduling-gate" label are ${pods_without_scheduling_gate}
Pods with "multiarch.openshift.io/node-affinity=set" label are ${pods_with_node_affinity_set}
Pods with "multiarch.openshift.io/node-affinity=not-set" label are ${pods_with_node_affinity_not_set}
Pods with pending status are ${pending_pods}
      ]]>
    </system-out>
  </testcase>
</testsuite>
EOF
    else
        cat <<EOF >"${ARTIFACT_DIR}/import-MTO.xml"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="mto perfscale test" tests="1" failures="1">
  <testcase name="mto perfscale test should succeed">
    <failure message="some pods don't get node affinity">
      <![CDATA[
The total test pods number is ${total_pods}
Pods with "multiarch.openshift.io/scheduling-gate=removed" label are ${pods_with_scheduling_gate_removed}
Pods without "multiarch.openshift.io/scheduling-gate" label are ${pods_without_scheduling_gate}
Pods with "multiarch.openshift.io/node-affinity=set" label are ${pods_with_node_affinity_set}
Pods with "multiarch.openshift.io/node-affinity=not-set" label are ${pods_with_node_affinity_not_set}
Pods with pending status are ${pending_pods}
      ]]>
    </failure>
  </testcase>
</testsuite>
EOF
    fi
}

pods=$(oc get pods -A -l ${POD_LABEL_FILTER} -o json)
total_pods=$(echo "$pods" | jq '.items | length')
pods_with_scheduling_gate_removed=$(echo "$pods" | jq '[.items[] | select(.metadata.labels."multiarch.openshift.io/scheduling-gate" == "removed")] | length')
pods_without_scheduling_gate=$(echo "$pods" | jq '[.items[] | select(.metadata.labels."multiarch.openshift.io/scheduling-gate" == null)] | length')
pods_with_node_affinity_set=$(echo "$pods" | jq '[.items[] | select(.metadata.labels."multiarch.openshift.io/node-affinity" == "set")] | length')
pods_with_node_affinity_not_set=$(echo "$pods" | jq '[.items[] | select(.metadata.labels."multiarch.openshift.io/node-affinity" == "not-set")] | length')
pending_pods=$(echo "$pods" | jq '[.items[] | select(.status.phase == "Pending" and (.status.conditions[]? | select(.type == "PodScheduled" and .reason == "SchedulingGated")))] | length')

if (( 
    pods_with_scheduling_gate_removed != total_pods ||
    pods_without_scheduling_gate != 0 ||
    pods_with_node_affinity_set != total_pods ||
    pods_with_node_affinity_not_set != 0 ||
    pending_pods != 0
    )); then
    echo "Not all pods get node affinity from MTO and PPC"
    exit 1
fi
