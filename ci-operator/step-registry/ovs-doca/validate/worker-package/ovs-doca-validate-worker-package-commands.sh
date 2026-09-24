#!/bin/bash

set -e
set -u
set -o pipefail

JUNIT_SUITE="OVS-DOCA Worker Package Validation"
FAILED=false

# Prow's JUnit lens parses a single top-level element from this file; without
# a wrapping <testsuites> root, only the first of the several <testsuite>
# blocks appended below would ever be parsed, silently dropping the rest.
JUNIT_FILE="${ARTIFACT_DIR}/junit_ovs_doca_validate.xml"
echo "<testsuites>" >"${JUNIT_FILE}"
trap 'echo "</testsuites>" >>"${JUNIT_FILE}"' EXIT

function record_pass() {
  local TEST_NAME=$1
  cat >>"${JUNIT_FILE}" <<EOF
<testsuite name="$JUNIT_SUITE" tests="1" failures="0">
  <testcase name="$TEST_NAME"/>
</testsuite>
EOF
}

function record_fail() {
  local TEST_NAME=$1
  local FAILURE_MESSAGE=$2
  FAILED=true
  cat >>"${JUNIT_FILE}" <<EOF
<testsuite name="$JUNIT_SUITE" tests="1" failures="1">
  <testcase name="$TEST_NAME">
    <failure message="">$FAILURE_MESSAGE
    </failure>
  </testcase>
</testsuite>
EOF
  echo "FAIL: $TEST_NAME -- $FAILURE_MESSAGE"
}

function set_proxy() {
  if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
    echo "Setting the proxy ${SHARED_DIR}/proxy-conf.sh"
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
  else
    echo "No proxy settings"
  fi
}

function debug_node() {
  local NODE=$1
  local CMD=$2
  oc debug -n default -q "$NODE" -- chroot /host bash -c "$CMD"
}

set_proxy

for NODE_ROLE in $OVS_DOCA_VALIDATE_NODE_ROLES; do
  echo "Validating nodes with role: $NODE_ROLE"

  NODES=$(oc get nodes -o name -l "node-role.kubernetes.io/$NODE_ROLE")
  if [ -z "$NODES" ]; then
    record_fail "$NODE_ROLE: at least one node selected" \
      "oc get nodes -l node-role.kubernetes.io/$NODE_ROLE returned no nodes"
    continue
  fi

  NODE_INDEX=0
  for NODE in $NODES; do
    NODE_INDEX=$((NODE_INDEX + 1))
    # Use a positional label instead of $NODE (an internal AWS hostname) in
    # anything that reaches CI logs/JUnit output; $NODE itself is only used
    # to target the debug pod, never printed.
    LABEL="${NODE_ROLE}-node-${NODE_INDEX}"
    echo "=== Checking $LABEL ==="

    # Check 1: doca-openvswitch package is installed (not just stock openvswitch)
    RPM_OUTPUT=$(debug_node "$NODE" "rpm -qa | grep vswitch || true")
    echo "$RPM_OUTPUT"
    if echo "$RPM_OUTPUT" | grep -q "^doca-openvswitch-"; then
      record_pass "$LABEL: doca-openvswitch package installed"
    else
      record_fail "$LABEL: doca-openvswitch package installed" \
        "doca-openvswitch not found in: $RPM_OUTPUT"
    fi

    # Check 2: OVS advertises the doca datapath type
    DATAPATH_OUTPUT=$(debug_node "$NODE" "ovs-vsctl list open_vswitch | grep datapath_types || true")
    echo "$DATAPATH_OUTPUT"
    if echo "$DATAPATH_OUTPUT" | grep -q "doca"; then
      record_pass "$LABEL: ovs-vsctl advertises doca datapath type"
    else
      record_fail "$LABEL: ovs-vsctl advertises doca datapath type" \
        "'doca' not found in datapath_types: $DATAPATH_OUTPUT"
    fi

    # Check 3: doca-init.service (offload tuning) ran successfully at boot
    SERVICE_STATUS=$(debug_node "$NODE" "systemctl is-enabled doca-init.service; systemctl is-active doca-init.service" || true)
    echo "$SERVICE_STATUS"
    if echo "$SERVICE_STATUS" | grep -q "^enabled$" && echo "$SERVICE_STATUS" | grep -q "^active$"; then
      record_pass "$LABEL: doca-init.service enabled and active"
    else
      record_fail "$LABEL: doca-init.service enabled and active" \
        "Unexpected systemctl output: $SERVICE_STATUS"
    fi

    # Check 4: hardware offload is disabled -- no DOCA-capable NIC on this
    # cluster, so OVS must run configured like a normal, non-offloaded switch
    HW_OFFLOAD=$(debug_node "$NODE" "ovs-vsctl get Open_vSwitch . other_config:hw-offload 2>/dev/null || echo 'unset'" | tr -d '"')
    echo "hw-offload: $HW_OFFLOAD"
    if [ "$HW_OFFLOAD" = "false" ]; then
      record_pass "$LABEL: hw-offload is disabled"
    else
      record_fail "$LABEL: hw-offload is disabled" \
        "Expected other_config:hw-offload=false, got: $HW_OFFLOAD"
    fi
  done
done

if $FAILED; then
  echo "One or more ovs-doca validation checks failed -- see above."
  exit 1
fi

echo "All ovs-doca worker package validation checks passed."
echo "NOTE: this only validates package/binary presence and that offload is disabled, not functional hardware offload (no DOCA-capable NIC on this cluster)."
