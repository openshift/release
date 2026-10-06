#!/bin/bash
# ---------------------------------------------------------------------------
# Post-ODF disk diagnostic step for OCS worker nodes
#
# Runs AFTER workerocs MachineSets are created by ACM policies and the
# MCP has reconciled (i.e. after interop-opp-wait-mcp).  Complements
# the early interop-opp-disk-diag step, which only sees the original
# IPI workers because the OCS storage nodes do not exist yet.
#
# This step:
#   1. Identifies OCS-labeled nodes specifically
#   2. Uses oc debug to capture real disk utilization (df -h) on each
#      OCS node -- something the early step deliberately avoids
#   3. Reports ephemeral-storage capacity vs allocatable for ALL nodes
#   4. Checks DiskPressure conditions on every node
#
# Best-effort -- must never fail the chain.
# ---------------------------------------------------------------------------

set -uo pipefail; shopt -s inherit_errexit

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

DIAG_DIR="${ARTIFACT_DIR}/disk-diag-ocs"
SUMMARY="${ARTIFACT_DIR}/disk-diagnostics-ocs.txt"
mkdir -p "${DIAG_DIR}"

echo "=== OPP Post-ODF Disk Diagnostics (OCS Nodes) ===" | tee "${SUMMARY}"

# -----------------------------------------------------------------------
# 1. Identify OCS-labeled worker nodes
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Identifying OCS worker nodes ---" | tee -a "${SUMMARY}"

OCS_NODES=()

# Look for nodes with the OCS storage label
if OCS_LIST="$(oc get nodes -l cluster.ocs.openshift.io/openshift-storage --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"; then
    while IFS= read -r node; do
        [[ -n "${node}" ]] && OCS_NODES+=("${node}")
    done <<< "${OCS_LIST}"
fi

# Also look for nodes with the workerocs role label
if WOCS_LIST="$(oc get nodes -l node-role.kubernetes.io/workerocs --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"; then
    while IFS= read -r node; do
        [[ -n "${node}" ]] || continue
        # Deduplicate
        local_dup=false
        for existing in "${OCS_NODES[@]+"${OCS_NODES[@]}"}"; do
            if [[ "${existing}" == "${node}" ]]; then
                local_dup=true
                break
            fi
        done
        if [[ "${local_dup}" == "false" ]]; then
            OCS_NODES+=("${node}")
        fi
    done <<< "${WOCS_LIST}"
fi

if [[ ${#OCS_NODES[@]} -eq 0 ]]; then
    echo "  No OCS-labeled nodes found (yet). Listing all nodes for reference:" | tee -a "${SUMMARY}"
    oc get nodes --show-labels 2>&1 | tee -a "${SUMMARY}" > "${DIAG_DIR}/all-nodes-labels.txt" || true
else
    echo "  Found ${#OCS_NODES[@]} OCS node(s): ${OCS_NODES[*]}" | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 2. oc debug -- capture real disk utilization on OCS nodes
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Real disk utilization on OCS nodes (df -h via oc debug) ---" | tee -a "${SUMMARY}"

for node in "${OCS_NODES[@]+"${OCS_NODES[@]}"}"; do
    echo "" | tee -a "${SUMMARY}"
    echo "  Node: ${node}" | tee -a "${SUMMARY}"
    DF_FILE="${DIAG_DIR}/df-${node}.txt"

    if DF_OUTPUT="$(timeout 120 oc debug "node/${node}" -- chroot /host df -h 2>&1)"; then
        echo "${DF_OUTPUT}" > "${DF_FILE}"
        echo "${DF_OUTPUT}" | tee -a "${SUMMARY}"
    else
        echo "  WARNING: oc debug failed for ${node}: ${DF_OUTPUT}" | tee -a "${SUMMARY}"
        echo "${DF_OUTPUT}" > "${DF_FILE}" 2>/dev/null || true
    fi
done

# -----------------------------------------------------------------------
# 3. Node capacity and allocatable ephemeral-storage (ALL nodes)
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Node ephemeral-storage capacity & allocatable (all nodes) ---" | tee -a "${SUMMARY}"

if NODE_JSON="$(oc get nodes -o json 2>/dev/null)"; then
    # Write only the fields needed for disk diagnostics -- strip addresses,
    # managedFields, and other potentially sensitive node metadata.
    python3 -c "
import json, sys
data = json.load(sys.stdin)
filtered = {'items': []}
for node in data.get('items', []):
    filtered['items'].append({
        'metadata': {
            'name': node.get('metadata', {}).get('name', ''),
            'labels': node.get('metadata', {}).get('labels', {}),
        },
        'status': {
            'capacity': node.get('status', {}).get('capacity', {}),
            'allocatable': node.get('status', {}).get('allocatable', {}),
            'conditions': node.get('status', {}).get('conditions', []),
        },
    })
json.dump(filtered, sys.stdout, indent=2)
" <<< "${NODE_JSON}" > "${DIAG_DIR}/nodes-storage-data.json"

    python3 -c "
import json, sys

data = json.load(sys.stdin)
fmt = '  {name:<55} {role:<12} {cap:>14} {alloc:>14} {ocs:<5}'
print(fmt.format(name='NODE', role='ROLE', cap='CAPACITY', alloc='ALLOCATABLE', ocs='OCS'))
print('  ' + '-' * 105)
for node in data.get('items', []):
    name = node['metadata']['name']
    labels = node['metadata'].get('labels', {})

    # Determine role
    if 'node-role.kubernetes.io/workerocs' in labels:
        role = 'workerocs'
    elif 'node-role.kubernetes.io/worker' in labels:
        role = 'worker'
    elif 'node-role.kubernetes.io/master' in labels:
        role = 'master'
    else:
        role = 'other'

    # OCS label check
    is_ocs = 'cluster.ocs.openshift.io/openshift-storage' in labels
    ocs_mark = '*OCS*' if is_ocs else ''

    cap = node.get('status', {}).get('capacity', {}).get('ephemeral-storage', 'n/a')
    alloc = node.get('status', {}).get('allocatable', {}).get('ephemeral-storage', 'n/a')

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

    print(fmt.format(name=name[:55], role=role, cap=to_ki(cap), alloc=to_ki(alloc), ocs=ocs_mark))
" <<< "${NODE_JSON}" 2>&1 | tee -a "${SUMMARY}"
else
    echo "  WARNING: Failed to fetch nodes" | tee -a "${SUMMARY}"
fi

# -----------------------------------------------------------------------
# 4. Node conditions -- DiskPressure check on ALL nodes
# -----------------------------------------------------------------------
echo "" | tee -a "${SUMMARY}"
echo "--- Node pressure conditions (all nodes) ---" | tee -a "${SUMMARY}"
if [[ -n "${NODE_JSON:-}" ]]; then
    python3 -c "
import json, sys

data = json.load(sys.stdin)
found = False
for node in data.get('items', []):
    name = node['metadata']['name']
    labels = node['metadata'].get('labels', {})
    is_ocs = 'cluster.ocs.openshift.io/openshift-storage' in labels
    ocs_tag = ' [OCS]' if is_ocs else ''
    conditions = node.get('status', {}).get('conditions', [])
    for cond in conditions:
        ctype = cond.get('type', '')
        if ctype in ('DiskPressure', 'MemoryPressure', 'PIDPressure') and cond.get('status') == 'True':
            found = True
            print(f'  WARNING: {name}{ocs_tag}: {ctype}=True reason={cond.get(\"reason\",\"\")} message={cond.get(\"message\",\"\")}')
if not found:
    print('  No pressure conditions detected on any node')
" <<< "${NODE_JSON}" 2>&1 | tee -a "${SUMMARY}"
fi

echo "" | tee -a "${SUMMARY}"
echo "=== Post-ODF disk diagnostics complete ===" | tee -a "${SUMMARY}"

# Always exit 0 -- this is a diagnostic step and must not fail the chain
exit 0
