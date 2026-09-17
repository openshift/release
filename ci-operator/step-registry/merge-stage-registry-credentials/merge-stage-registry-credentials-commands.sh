#!/bin/bash
#
# Merge registry.stage.redhat.io credentials into the cluster global pull-secret
# and wait for the Machine Config Operator (MCO) to roll the change out to nodes.
#
# CI mounts stage credentials from the openshift-custom-mirror-registry secret at
# STAGE_REGISTRY_PATH. Updating openshift-config/pull-secret triggers MCO to
# render new MachineConfigs and update each MachineConfigPool (MCP).
#
# Callers should run this step before operator install or e2e tests that pull
# images from registry.stage.redhat.io.

set -euo pipefail

STAGE_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_stage.json"
PULL_SECRET_WORKDIR="/tmp/merge-stage-registry-credentials"

# Proxy-enabled install workflows write HTTP(S)_PROXY settings here. Steps that
# talk to the API server after install must source it, same as operator-sdk steps.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090,SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Snapshot fields that change when MCO reacts to a pull-secret update. A single
# composite string makes it easy to detect a real rollout vs. a steady-state MCP
# that already reports Updated=True from before the secret was changed.
#
# Returns the fingerprint on stdout. Callers must check the exit status; do not
# call via command substitution without an explicit guard because a failed oc get
# must abort the step, not be treated as empty output.
capture_mcp_rollout_state() {
    local mcp="$1"
    oc get mcp "${mcp}" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.status.configuration.name}|{.status.updatedMachineCount}|{.status.machineCount}|{.status.conditions[?(@.type=="Updating")].status}|{.status.conditions[?(@.type=="Updated")].status}|{.status.conditions[?(@.type=="Updated")].lastTransitionTime}'
}

# Bash disables errexit while evaluating functions used as if conditions. Guard
# oc get explicitly so API failures cannot be mistaken for machineCount=0.
mcp_has_machines() {
    local mcp="$1"
    local machine_count
    if ! machine_count=$(oc get mcp "${mcp}" -o jsonpath='{.status.machineCount}'); then
        echo "Failed to read machine count for MCP ${mcp}" >&2
        exit 1
    fi
    [[ "${machine_count:-0}" -gt 0 ]]
}

rollout_state_changed() {
    local mcp="$1"
    local pre_state="$2"
    local current_state
    if ! current_state=$(capture_mcp_rollout_state "${mcp}"); then
        echo "Failed to read rollout state for MCP ${mcp}" >&2
        exit 1
    fi
    [[ "${current_state}" != "${pre_state}" ]]
}

# Updated=True alone is not sufficient: an MCP can remain Updated from a prior
# rollout. Require a post-update state transition, quiescent Updating, and full
# machine sync before treating the pool as done.
mcp_rollout_complete() {
    local mcp="$1"
    local pre_state="$2"
    local updated updating machine_count updated_machine_count
    if ! updated=$(oc get mcp "${mcp}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}'); then
        echo "Failed to read Updated condition for MCP ${mcp}" >&2
        exit 1
    fi
    if ! updating=$(oc get mcp "${mcp}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}'); then
        echo "Failed to read Updating condition for MCP ${mcp}" >&2
        exit 1
    fi
    if ! machine_count=$(oc get mcp "${mcp}" -o jsonpath='{.status.machineCount}'); then
        echo "Failed to read machine count for MCP ${mcp}" >&2
        exit 1
    fi
    if ! updated_machine_count=$(oc get mcp "${mcp}" -o jsonpath='{.status.updatedMachineCount}'); then
        echo "Failed to read updatedMachineCount for MCP ${mcp}" >&2
        exit 1
    fi

    echo "MCP ${mcp} Updated=${updated:-unknown} Updating=${updating:-unknown} synced=${updated_machine_count:-unknown}/${machine_count:-unknown}"

    [[ "${updated}" == "True" ]] \
        && [[ "${updating}" != "True" ]] \
        && [[ "${updated_machine_count}" == "${machine_count}" ]] \
        && rollout_state_changed "${mcp}" "${pre_state}"
}

if [[ ! -f "${STAGE_REGISTRY_PATH}" ]]; then
    echo "Stage registry credentials not found at ${STAGE_REGISTRY_PATH}"
    exit 1
fi

# Discover MCPs before mutating the pull-secret so we can fail fast on clusters
# without MCO (and avoid updating the secret when rollout cannot be monitored).
echo "Discovering MachineConfigPools..."
mcp_names=""
if ! mcp_names=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); then
    echo "Failed to list MachineConfigPools" >&2
    exit 1
fi
mapfile -t MCP_POOLS < <(printf '%s\n' "${mcp_names}" | sed '/^$/d')
if [[ ${#MCP_POOLS[@]} -eq 0 ]]; then
    echo "No MachineConfigPools found in cluster; aborting before pull-secret update"
    exit 1
fi
echo "MachineConfigPools present: ${MCP_POOLS[*]}"

# Baselines are captured before the pull-secret update. Only pools with nodes
# participate in rollout verification; empty pools never receive kubelet creds.
MCPS_NEEDING_ROLLOUT=()
declare -A MCP_PRE_STATE=()
for mcp in "${MCP_POOLS[@]}"; do
    if ! MCP_PRE_STATE["${mcp}"]=$(capture_mcp_rollout_state "${mcp}"); then
        echo "Failed to read rollout state for MCP ${mcp}" >&2
        exit 1
    fi
    echo "MCP ${mcp} pre-update rollout state: ${MCP_PRE_STATE[${mcp}]}"
    if mcp_has_machines "${mcp}"; then
        MCPS_NEEDING_ROLLOUT+=("${mcp}")
    fi
done

mkdir -p "${PULL_SECRET_WORKDIR}"

echo "Extracting current cluster pull secret..."
oc extract secret/pull-secret -n openshift-config --confirm --to "${PULL_SECRET_WORKDIR}"
if [[ ! -f "${PULL_SECRET_WORKDIR}/.dockerconfigjson" ]]; then
    echo "Cluster pull secret was not extracted to ${PULL_SECRET_WORKDIR}/.dockerconfigjson"
    exit 1
fi
if ! jq -e . "${PULL_SECRET_WORKDIR}/.dockerconfigjson" >/dev/null; then
    echo "Extracted cluster pull secret is not valid JSON"
    exit 1
fi

echo "Merging registry.stage.redhat.io credentials..."
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
# Disable tracing while handling registry credentials.
set +x
# jq -er rejects missing, null, or empty user/password before we touch the secret.
stage_auth_user=$(jq -er '.user | strings | select(length > 0)' "${STAGE_REGISTRY_PATH}")
stage_auth_password=$(jq -er '.password | strings | select(length > 0)' "${STAGE_REGISTRY_PATH}")
stage_registry_auth=$(printf '%s:%s' "${stage_auth_user}" "${stage_auth_password}" | base64 -w 0)

jq --argjson stage "{\"registry.stage.redhat.io\": {\"auth\": \"${stage_registry_auth}\"}}" \
   '.auths |= . + $stage' "${PULL_SECRET_WORKDIR}/.dockerconfigjson" > "${PULL_SECRET_WORKDIR}/new-dockerconfigjson"
$WAS_TRACING && set -x

if ! jq -e '.auths["registry.stage.redhat.io"].auth' "${PULL_SECRET_WORKDIR}/new-dockerconfigjson" >/dev/null; then
    echo "Failed to merge registry.stage.redhat.io credentials into pull secret"
    exit 1
fi

echo "Updating cluster pull secret..."
oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson="${PULL_SECRET_WORKDIR}/new-dockerconfigjson"

# Nothing to roll out when every MCP has machineCount=0; the secret update is
# still useful for future nodes but there is no kubelet config to wait on.
if [[ ${#MCPS_NEEDING_ROLLOUT[@]} -eq 0 ]]; then
    echo "No MachineConfigPools with machines; pull-secret updated without rollout wait"
    exit 0
fi

# Phase 1: confirm MCO started reacting to the pull-secret change. Without this
# gate, a pool that was already Updated=True could let the step exit before any
# node picked up the new credentials.
echo "Waiting for MachineConfigPool rollout evidence after pull-secret update..."
COUNTER=0
rollout_evidence=false
while [ $COUNTER -lt 120 ]; do
    for mcp in "${MCPS_NEEDING_ROLLOUT[@]}"; do
        if ! updating=$(oc get mcp "${mcp}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}'); then
            echo "Failed to read Updating condition for MCP ${mcp}" >&2
            exit 1
        fi
        state_changed=false
        if rollout_state_changed "${mcp}" "${MCP_PRE_STATE[${mcp}]}"; then
            state_changed=true
        fi
        echo "MCP ${mcp} Updating=${updating:-unknown} state_changed=${state_changed} (${COUNTER}s elapsed)"

        if [[ "${updating}" == "True" || "${state_changed}" == "true" ]]; then
            rollout_evidence=true
        fi
    done
    if [[ "${rollout_evidence}" == "true" ]]; then
        echo "MachineConfigPool rollout evidence observed."
        break
    fi

    sleep 20
    COUNTER=$((COUNTER + 20))
done

if [[ "${rollout_evidence}" != "true" ]]; then
    echo "No MachineConfigPool rollout evidence observed within ${COUNTER}s after pull-secret update"
    for mcp in "${MCPS_NEEDING_ROLLOUT[@]}"; do
        echo "MCP ${mcp} pre-update state:  ${MCP_PRE_STATE[${mcp}]}"
        current_state="unavailable"
        if current_state=$(capture_mcp_rollout_state "${mcp}"); then
            :
        fi
        echo "MCP ${mcp} current state:    ${current_state}"
        oc get mcp "${mcp}" -o yaml || true
    done
    exit 1
fi

# Phase 2: wait until every pool with nodes finishes rolling out the new config.
echo "Waiting for MachineConfigPool(s) to finish updating..."
COUNTER=0
while [ $COUNTER -lt 420 ]; do
    all_updated=true
    for mcp in "${MCPS_NEEDING_ROLLOUT[@]}"; do
        echo "Checking MCP ${mcp} rollout status (${COUNTER}s elapsed)"
        if ! mcp_rollout_complete "${mcp}" "${MCP_PRE_STATE[${mcp}]}"; then
            all_updated=false
        fi
    done
    if [[ "${all_updated}" == "true" ]]; then
        echo "MachineConfigPool rollout complete."
        exit 0
    fi

    sleep 20
    COUNTER=$((COUNTER + 20))
done

echo "MachineConfigPool rollout timed out after ${COUNTER}s"
for mcp in "${MCPS_NEEDING_ROLLOUT[@]}"; do
    oc get mcp "${mcp}" -o yaml || true
done
exit 1
