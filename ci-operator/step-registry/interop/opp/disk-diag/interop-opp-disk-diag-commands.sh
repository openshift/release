#!/bin/bash
# ---------------------------------------------------------------------------
# OPP disk-layout diagnostic step
#
# Captures disk layout and ephemeral-storage information from cluster
# nodes to help diagnose why the RHCOS root filesystem may not be
# expanding to fill the configured EBS volume.  This is a best-effort
# diagnostic step -- it must never fail the chain.
#
# Uses only unprivileged oc commands (no node debug sessions).
# ---------------------------------------------------------------------------

set -uo pipefail; shopt -s inherit_errexit

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

DIAG_DIR="${ARTIFACT_DIR}/disk-diag"
SUMMARY="${ARTIFACT_DIR}/disk-diagnostics.txt"
mkdir -p "${DIAG_DIR}"

echo "=== OPP Disk Diagnostics ===" | tee "${SUMMARY}"

# -----------------------------------------------------------------------
# 1. Node capacity and allocatable ephemeral-storage (from the API)
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Node ephemeral-storage capacity & allocatable ---" | tee -a "${SUMMARY}"

if NODE_JSON="$(oc get nodes -o json 2>/dev/null)"; then
    echo "${NODE_JSON}" > "${DIAG_DIR}/nodes-full.json"

    python3 -c "
import json, sys

data = json.load(sys.stdin)
fmt = '  {name:<55} {role:<8} {cap:>14} {alloc:>14} {avail:>14}'
print(fmt.format(name='NODE', role='ROLE', cap='CAPACITY', alloc='ALLOCATABLE', avail='AVAIL(Ki)'))
print('  ' + '-' * 105)
for node in data.get('items', []):
    name = node['metadata']['name']
    labels = node['metadata'].get('labels', {})
    role = 'worker' if 'node-role.kubernetes.io/worker' in labels else \
           'master' if 'node-role.kubernetes.io/master' in labels else 'other'
    cap = node.get('status', {}).get('capacity', {}).get('ephemeral-storage', 'n/a')
    alloc = node.get('status', {}).get('allocatable', {}).get('ephemeral-storage', 'n/a')

    # Convert to Ki for readability if the value is in bytes (bare number)
    def to_ki(val):
        if val == 'n/a':
            return val
        try:
            if val.endswith('Ki'):
                return val
            elif val.endswith('Mi'):
                return str(int(val[:-2]) * 1024) + 'Ki'
            elif val.endswith('Gi'):
                return str(int(val[:-2]) * 1024 * 1024) + 'Ki'
            else:
                return str(int(val) // 1024) + 'Ki'
        except (ValueError, TypeError):
            return val

    cap_ki = to_ki(cap)
    alloc_ki = to_ki(alloc)

    # Compute approximate available vs 10% eviction threshold
    avail_note = ''
    try:
        if cap.endswith('Ki'):
            cap_bytes = int(cap[:-2]) * 1024
        elif cap.endswith('Mi'):
            cap_bytes = int(cap[:-2]) * 1024 * 1024
        elif cap.endswith('Gi'):
            cap_bytes = int(cap[:-2]) * 1024 * 1024 * 1024
        else:
            cap_bytes = int(cap)
        threshold_10pct = cap_bytes * 0.10
        avail_note = '(10%%_threshold=%dKi)' % (threshold_10pct // 1024)
    except (ValueError, TypeError):
        pass

    print(fmt.format(name=name[:55], role=role, cap=cap_ki, alloc=alloc_ki, avail=avail_note))
" <<< "${NODE_JSON}" 2>&1 | tee -a "${SUMMARY}"
else
    echo "  WARNING: Failed to fetch nodes" | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 2. oc adm top nodes — actual resource usage
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Node resource usage (oc adm top nodes) ---" | tee -a "${SUMMARY}"
if TOP_OUTPUT="$(oc adm top nodes --no-headers 2>&1)"; then
    echo "${TOP_OUTPUT}" | tee -a "${SUMMARY}"
    echo "${TOP_OUTPUT}" > "${DIAG_DIR}/top-nodes.txt"
else
    echo "  WARNING: oc adm top nodes failed: ${TOP_OUTPUT}" | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 3. Node conditions — look for DiskPressure or MemoryPressure
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Node pressure conditions ---" | tee -a "${SUMMARY}"
if [[ -n "${NODE_JSON:-}" ]]; then
    python3 -c "
import json, sys

data = json.load(sys.stdin)
found = False
for node in data.get('items', []):
    name = node['metadata']['name']
    conditions = node.get('status', {}).get('conditions', [])
    for cond in conditions:
        ctype = cond.get('type', '')
        if ctype in ('DiskPressure', 'MemoryPressure', 'PIDPressure') and cond.get('status') == 'True':
            found = True
            print(f'  WARNING: {name}: {ctype}=True reason={cond.get(\"reason\",\"\")} message={cond.get(\"message\",\"\")}')
if not found:
    print('  No pressure conditions detected on any node')
" <<< "${NODE_JSON}" 2>&1 | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 4. KubeletConfiguration (cluster-level)
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- KubeletConfig CRs ---" | tee -a "${SUMMARY}"
if KC_OUTPUT="$(oc get kubeletconfigs -o yaml 2>&1)"; then
    echo "${KC_OUTPUT}" > "${DIAG_DIR}/kubeletconfig.yaml"
    echo "  Saved to ${DIAG_DIR}/kubeletconfig.yaml" | tee -a "${SUMMARY}"
else
    echo "  No KubeletConfig CRs found or query failed" | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 5. MachineConfigPool status
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- MachineConfigPool status ---" | tee -a "${SUMMARY}"
if MCP_OUTPUT="$(oc get mcp -o wide 2>&1)"; then
    echo "${MCP_OUTPUT}" | tee -a "${SUMMARY}"
    echo "${MCP_OUTPUT}" > "${DIAG_DIR}/mcp-status.txt"
else
    echo "  WARNING: oc get mcp failed: ${MCP_OUTPUT}" | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 6. Pod eviction events (ephemeral-storage related)
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Recent eviction events ---" | tee -a "${SUMMARY}"
if EVENTS="$(oc get events --all-namespaces --field-selector reason=Evicted -o json 2>/dev/null)"; then
    echo "${EVENTS}" > "${DIAG_DIR}/eviction-events.json"
    python3 -c "
import json, sys

data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
    print('  No eviction events found')
else:
    print(f'  Found {len(items)} eviction event(s):')
    for ev in items[:20]:
        ns = ev.get('involvedObject', {}).get('namespace', '')
        name = ev.get('involvedObject', {}).get('name', '')
        msg = ev.get('message', '')[:120]
        ts = ev.get('lastTimestamp', ev.get('eventTime', ''))
        print(f'    {ts} {ns}/{name}: {msg}')
    if len(items) > 20:
        print(f'    ... and {len(items) - 20} more (see eviction-events.json)')
" <<< "${EVENTS}" 2>&1 | tee -a "${SUMMARY}"
else
    echo "  WARNING: Failed to query eviction events" | tee -a "${SUMMARY}"
fi

echo "" | tee -a "${SUMMARY}"
echo "=== Disk diagnostics complete ===" | tee -a "${SUMMARY}"

# Always exit 0 -- this is a diagnostic step and must not fail the chain
exit 0
