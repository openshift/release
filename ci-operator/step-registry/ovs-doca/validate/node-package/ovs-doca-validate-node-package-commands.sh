#!/bin/bash

set -e
set -u
set -o pipefail

JUNIT_SUITE="OVS-DOCA Node Package Validation"
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

    # Check 1: openvswitch is actually running. Layering OVS into the ostree
    # commit is precisely where this breaks -- doca-openvswitch carries
    # /var/lib/openvswitch as rpm payload with no tmpfiles.d entry, and
    # `ostree container commit` discards /var -- so gate on daemon health
    # first. Without this the later checks fail with confusing ovs-vsctl
    # connection errors instead of naming the real problem.
    OVS_ACTIVE=$(debug_node "$NODE" "systemctl is-active openvswitch || true")
    echo "openvswitch: $OVS_ACTIVE"
    if [ "$OVS_ACTIVE" = "active" ]; then
      record_pass "$LABEL: openvswitch service is active"
    else
      record_fail "$LABEL: openvswitch service is active" \
        "systemctl is-active openvswitch returned: $OVS_ACTIVE"
    fi

    # Check 2: doca-openvswitch package is installed (not just stock openvswitch)
    RPM_OUTPUT=$(debug_node "$NODE" "rpm -qa | grep vswitch || true")
    echo "$RPM_OUTPUT"
    if echo "$RPM_OUTPUT" | grep -q "^doca-openvswitch-"; then
      record_pass "$LABEL: doca-openvswitch package installed"
    else
      record_fail "$LABEL: doca-openvswitch package installed" \
        "doca-openvswitch not found in: $RPM_OUTPUT"
    fi

    # ...and that it actually *replaced* stock OVS rather than landing beside
    # it. doca-openvswitch declares `Obsoletes: openvswitch`, but RHCOS ships
    # the version-suffixed Fast Datapath name (openvswitch3.5), which that
    # obsoletes clause does not cover -- the image build's explicit
    # `dnf remove 'openvswitch[0-9]*'` is what removes it, so assert the
    # result rather than assuming it worked.
    if echo "$RPM_OUTPUT" | grep -qE "^openvswitch[0-9]"; then
      record_fail "$LABEL: stock openvswitch removed" \
        "Fast Datapath openvswitch still installed alongside doca-openvswitch: $RPM_OUTPUT"
    else
      record_pass "$LABEL: stock openvswitch removed"
    fi

    # Diagnostic only, deliberately not asserted. doca-openvswitch ships no
    # SELinux policy of its own, so the node relies on whatever policy the
    # base image already carries. openvswitch-selinux-extra-policy is not
    # matched by the removal glob above, but dnf's clean_requirements_on_remove
    # may still drop it as an orphaned dependency of openvswitch3.x. Whether
    # its absence actually breaks anything is unconfirmed, so print it for
    # correlation against any AVC denials instead of guessing at a verdict.
    SELINUX_POLICY=$(debug_node "$NODE" "rpm -q openvswitch-selinux-extra-policy 2>&1 || true")
    echo "openvswitch-selinux-extra-policy: $SELINUX_POLICY"

    # Check 3: OVS advertises the doca datapath type
    DATAPATH_OUTPUT=$(debug_node "$NODE" "ovs-vsctl list open_vswitch | grep datapath_types || true")
    echo "$DATAPATH_OUTPUT"
    if echo "$DATAPATH_OUTPUT" | grep -q "doca"; then
      record_pass "$LABEL: ovs-vsctl advertises doca datapath type"
    else
      record_fail "$LABEL: ovs-vsctl advertises doca datapath type" \
        "'doca' not found in datapath_types: $DATAPATH_OUTPUT"
    fi

    # Check 4: offload is disabled -- no DOCA-capable NIC on this cluster, so
    # OVS must run like a normal, non-offloaded switch. Nothing writes these
    # keys: the image ships no tuning unit, and OVS treats an absent key
    # exactly as false (ovs-vswitchd logs "DOCA Disabled - Use
    # other_config:doca-init to enable" and never enables the flow API, which
    # additionally needs hw-offload=true). So absent is the expected steady
    # state -- accept it alongside an explicit false, and fail only on true.
    for KEY in hw-offload doca-init; do
      VALUE=$(debug_node "$NODE" "ovs-vsctl get Open_vSwitch . other_config:$KEY 2>/dev/null || echo unset" | tr -d '"')
      echo "$KEY: $VALUE"
      if [ "$VALUE" = "false" ] || [ "$VALUE" = "unset" ]; then
        record_pass "$LABEL: $KEY is disabled ($VALUE)"
      else
        record_fail "$LABEL: $KEY is disabled" \
          "Expected other_config:$KEY to be false or absent, got: $VALUE"
      fi
    done
  done
done

if $FAILED; then
  echo "One or more ovs-doca validation checks failed -- see above."
  exit 1
fi

echo "All ovs-doca node package validation checks passed."
echo "NOTE: this only validates package/binary presence and that offload is disabled, not functional hardware offload (no DOCA-capable NIC on this cluster)."
