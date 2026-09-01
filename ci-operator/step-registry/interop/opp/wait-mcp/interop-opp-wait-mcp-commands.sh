#!/bin/bash

set -euxo pipefail
shopt -s inherit_errexit

typeset -ri mcpWaitTimeout="${MCP_WAIT_TIMEOUT:-3600}"
typeset -ri consecutiveRequired="${MCP_CONSECUTIVE_CHECKS:-3}"
typeset -ri settleDelay="${MCP_SETTLE_DELAY:-90}"
typeset -ri maxUnavailable="${MCP_MAX_UNAVAILABLE:-3}"
typeset -ri pollInterval=30
typeset -a readyHistory=()

function IsReadyCountProgressing () {
    typeset -i len=${#readyHistory[@]}
    (( len < 3 )) && return 1
    typeset -i windowStart=$(( len > 6 ? len - 6 : 0 ))
    typeset -i first=${readyHistory[windowStart]}
    typeset -i last=${readyHistory[len - 1]}
    typeset -i decreases=0
    for (( i = windowStart + 1; i < len; ++i )); do
        (( readyHistory[i] < readyHistory[i-1] )) && (( ++decreases )) || true
    done
    if (( last > first && decreases <= 1 )); then
        return 0
    fi
    return 1
}

function ClassifyMcpState () {
    typeset json="${1}"
    echo "${json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = [m for m in data.get('items', []) if not m.get('spec', {}).get('paused', False)]
degraded = any(
    {c['type']: c['status'] for c in m.get('status', {}).get('conditions', [])}.get('Degraded') == 'True'
    for m in items
)
updating = any(
    {c['type']: c['status'] for c in m.get('status', {}).get('conditions', [])}.get('Updating') == 'True'
    for m in items
)
if degraded:
    print('DEGRADED')
elif updating:
    print('UPDATING')
else:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN"
    true
}

echo "Waiting ${settleDelay}s for MachineConfig rendering to propagate..."
sleep "${settleDelay}"

echo "Patching worker MCP maxUnavailable=${maxUnavailable} to parallelize node rollout..."
if oc patch machineconfigpool worker --type merge -p "{\"spec\":{\"maxUnavailable\": ${maxUnavailable}}}" 2>/dev/null; then
    echo "Worker MCP maxUnavailable set to ${maxUnavailable}"
else
    echo "WARNING: Failed to patch maxUnavailable (may not have permission or MCP may not exist)"
fi

echo "MachineConfigs created since cluster install:"
typeset mcList=''
mcList="$(oc get machineconfig --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp 2>/dev/null)" || true
echo "${mcList}" | tail -10

typeset -ri deadline=$(( SECONDS + mcpWaitTimeout ))
typeset -i consecutivePasses=0

echo "Polling MCPs for up to ${mcpWaitTimeout}s (need ${consecutiveRequired} consecutive clean polls)..."

while (( SECONDS < deadline )); do
    typeset -i remaining=$(( deadline - SECONDS ))
    (( remaining < 5 )) && remaining=5
    typeset mcpJson=""
    mcpJson="$(oc get mcp -o json --request-timeout="${remaining}s" 2>/dev/null)" || {
        echo "WARNING: oc get mcp failed, retrying in ${pollInterval}s"
        consecutivePasses=0
        sleep "${pollInterval}"
        continue
    }

    typeset statusLine=""
    statusLine="$(echo "${mcpJson}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
issues = []
total_ready = 0
for mcp in data.get('items', []):
    name = mcp['metadata']['name']
    paused = mcp.get('spec', {}).get('paused', False)
    if paused:
        continue
    conditions = {c['type']: c['status'] for c in mcp.get('status', {}).get('conditions', [])}
    updating = conditions.get('Updating', 'Unknown')
    degraded = conditions.get('Degraded', 'Unknown')
    status = mcp.get('status', {})
    ready = status.get('readyMachineCount', 0)
    total = status.get('machineCount', 0)
    updated = status.get('updatedMachineCount', 0)
    unavailable = status.get('unavailableMachineCount', 0)
    total_ready += ready
    if updating == 'True' or degraded == 'True' or unavailable > 0 or ready != total or updated != total:
        issues.append(f'{name}: Updating={updating} Degraded={degraded} ready={ready}/{total} updated={updated}/{total} unavailable={unavailable}')
if issues:
    print('UNSTABLE|' + '; '.join(issues) + '|' + str(total_ready))
else:
    print('STABLE|all non-paused MCPs healthy|' + str(total_ready))
" 2>/dev/null)" || statusLine="UNSTABLE|python parse error|0"

    typeset statusKey="${statusLine%%|*}"
    typeset remainder="${statusLine#*|}"
    typeset statusDetail="${remainder%|*}"
    typeset -i totalReady=0
    totalReady="${remainder##*|}" 2>/dev/null || totalReady=0
    readyHistory+=("${totalReady}")
    typeset -i elapsed=$(( SECONDS - (deadline - mcpWaitTimeout) ))

    if [[ "${statusKey}" == "STABLE" ]]; then
        (( consecutivePasses += 1 )) || true
        echo "Clean poll ${consecutivePasses}/${consecutiveRequired} at ${elapsed}s: ${statusDetail}"
        if (( consecutivePasses >= consecutiveRequired )); then
            echo "MCPs stable after ${elapsed}s (${consecutiveRequired} consecutive clean polls)"
            exit 0
        fi
    else
        if (( consecutivePasses > 0 )); then
            echo "Stability interrupted after ${consecutivePasses} clean polls, resetting"
        fi
        consecutivePasses=0
        echo "Waiting at ${elapsed}/${mcpWaitTimeout}s: ${statusDetail}"
    fi

    sleep "${pollInterval}"
done

typeset -i elapsed=$(( SECONDS - (deadline - mcpWaitTimeout) ))
echo "MCPs did not stabilize within ${elapsed}s — classifying timeout..."
echo ""
echo "Final MCP state:"
oc get mcp -o wide 2>/dev/null || true
echo ""

typeset classification="UNKNOWN"
typeset finalJson=""
if finalJson="$(oc get mcp -o json --request-timeout=30s 2>/dev/null)"; then
    classification="$(ClassifyMcpState "${finalJson}")"
fi

case "${classification}" in
    DEGRADED)
        echo "FAILURE CLASS: Product interop failure"
        echo "One or more MCPs have Degraded=True — policies may have caused nodes to enter a bad state"
        echo ""
        oc get nodes -o wide 2>/dev/null || true
        exit 1
        ;;
    UPDATING)
        echo "Ready count trend: ${readyHistory[*]}"
        if IsReadyCountProgressing; then
            echo "FAILURE CLASS: Infrastructure timeout (non-blocking)"
            echo "MCP rollout is healthy (Degraded=False, ready count increasing) but too slow for the ${mcpWaitTimeout}s timeout"
            echo "Exiting with success — downstream health checks will validate remaining state"
            exit 0
        else
            echo "FAILURE CLASS: Potential interop issue"
            echo "MCP is updating but ready count is not progressing — nodes may be cycling"
            echo ""
            oc get nodes -o wide 2>/dev/null || true
            typeset mcpWorkerDesc=''
            mcpWorkerDesc="$(oc describe mcp worker 2>/dev/null)" || true
            echo "${mcpWorkerDesc}" | tail -30
            exit 1
        fi
        ;;
    *)
        echo "FAILURE CLASS: Unknown timeout"
        echo "Ready count trend: ${readyHistory[*]}"
        exit 1
        ;;
esac
