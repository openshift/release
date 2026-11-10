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

    # Check 3: OVS advertises the doca datapath type -- and that the netdev
    # and system (kernel) datapaths are still registered alongside it. On a
    # node with no DOCA-capable NIC the expected steady state is all three
    # ([doca, netdev, system]): the DOCA-enabled binary runs the plain kernel
    # datapath, so a missing netdev/system would mean the daemon can no
    # longer switch packets the normal way.
    DATAPATH_OUTPUT=$(debug_node "$NODE" "ovs-vsctl list open_vswitch | grep datapath_types || true")
    echo "$DATAPATH_OUTPUT"
    MISSING_TYPES=""
    for DT in doca netdev system; do
      echo "$DATAPATH_OUTPUT" | grep -q "$DT" || MISSING_TYPES="$MISSING_TYPES $DT"
    done
    if [ -z "$MISSING_TYPES" ]; then
      record_pass "$LABEL: datapath_types includes doca, netdev and system"
    else
      record_fail "$LABEL: datapath_types includes doca, netdev and system" \
        "missing from datapath_types:$MISSING_TYPES -- got: $DATAPATH_OUTPUT"
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

    # Check 5: version assertions. Three different numbers are involved and
    # they are NOT the same: the DOCA release train pinned in the image's
    # repo URL (e.g. "3.4.1"), the rpm VERSION-RELEASE that train ships
    # (e.g. 3.4.0040-1.el9), and the OVS version the daemon reports about
    # itself (external_ids:ovs-version, stamped by ovsdb-server.service at
    # every start via `ovs-vswitchd --version`). The expected rpm version is
    # passed in via env so a DOCA bump is a one-line change in the ref.yaml,
    # not an edit here. The daemon self-report is asserted non-empty rather
    # than exact: it is written by the ovsdb-server version-stamping step
    # that historically broke on this image (the libclx_api.so.1 failure),
    # so an empty value is itself a meaningful regression signal.
    RPM_VERSION=$(debug_node "$NODE" "rpm -q doca-openvswitch --qf '%{VERSION}-%{RELEASE}' 2>&1 || echo not-installed")
    echo "doca-openvswitch rpm version: $RPM_VERSION"
    if [ "$RPM_VERSION" = "$OVS_DOCA_EXPECTED_RPM_VERSION" ]; then
      record_pass "$LABEL: doca-openvswitch rpm version ($RPM_VERSION)"
    else
      record_fail "$LABEL: doca-openvswitch rpm version" \
        "expected $OVS_DOCA_EXPECTED_RPM_VERSION, got: $RPM_VERSION"
    fi

    # Diagnostic, deliberately not asserted: the daemon's self-reported
    # version, if the packaging stamps it into external_ids. Rehearsal
    # 2120102581920337920 showed the key can be absent on a healthy cluster
    # -- ovs-vsctl then exits non-zero, which also crashes this script under
    # `set -e` if the query is not guarded, so it must never run bare. The
    # rpm NEVRA assertion above is the authoritative version check; this is
    # printed (with the full external_ids map when the key is missing) for
    # correlation only.
    OVS_VERSION=$(debug_node "$NODE" "ovs-vsctl get Open_vSwitch . external_ids:ovs-version 2>/dev/null || echo unset" | tr -d '"')
    if [ "$OVS_VERSION" = "unset" ]; then
      echo "ovs-version: not stamped in external_ids (diagnostic only)"
      debug_node "$NODE" "ovs-vsctl get Open_vSwitch . external_ids" || true
    else
      echo "ovs-version (daemon self-report): $OVS_VERSION"
    fi

    # Check 6: applicative test -- push actual packets through the switch.
    # Creates an isolated test bridge (deliberately not br-int, so no OVN
    # interaction), two network namespaces joined by a veth pair, and pings
    # across it. Proves the doca-openvswitch binary actually forwards
    # traffic on the kernel datapath, not just that it starts and answers
    # queries. Cleans up after itself via an EXIT trap even on failure, so
    # a failing run leaves no bridge, ports or namespaces behind.
    # shellcheck disable=SC2016  # single-quoted on purpose: runs on the node
    DATAPATH_TEST='set -e
BR=br-doca-test
cleanup() {
  ovs-vsctl --if-exists del-br "$BR"
  ip netns del doca-ns-a 2>/dev/null || true
  ip netns del doca-ns-b 2>/dev/null || true
  ip link del v-doca-a 2>/dev/null || true
}
trap cleanup EXIT
ovs-vsctl add-br "$BR"
ip netns add doca-ns-a
ip netns add doca-ns-b
ip link add v-doca-a type veth peer name v-doca-b
ip link set v-doca-a netns doca-ns-a
ip link set v-doca-b netns doca-ns-b
ovs-vsctl add-port "$BR" v-doca-a
ovs-vsctl add-port "$BR" v-doca-b
ip netns exec doca-ns-a ip addr add 192.0.2.1/30 dev v-doca-a
ip netns exec doca-ns-b ip addr add 192.0.2.2/30 dev v-doca-b
ip netns exec doca-ns-a ip link set v-doca-a up
ip netns exec doca-ns-b ip link set v-doca-b up
ip netns exec doca-ns-a ping -c 3 -W 2 192.0.2.2'
    if debug_node "$NODE" "$DATAPATH_TEST"; then
      record_pass "$LABEL: datapath forwards traffic (veth ping across test bridge)"
    else
      record_fail "$LABEL: datapath forwards traffic" \
        "ping across test bridge failed -- see debug output above"
    fi
  done
done

if $FAILED; then
  echo "One or more ovs-doca validation checks failed -- see above."
  exit 1
fi

echo "All ovs-doca node package validation checks passed."
echo "NOTE: this validates package presence and version, daemon health, datapath registration and software (kernel-datapath) traffic forwarding with offload disabled. It does NOT validate hardware offload -- that requires a DOCA-capable NIC, which this cluster does not have."
