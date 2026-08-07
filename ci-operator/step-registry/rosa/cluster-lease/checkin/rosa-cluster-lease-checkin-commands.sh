#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
CLAIM_FILE="${SHARED_DIR}/lease-claim"

if [[ ! -f "${CLAIM_FILE}" ]]; then
    log "No lease claim found (${CLAIM_FILE} does not exist). Nothing to check in."
    exit 0
fi

CM_NAME=$(cat "${CLAIM_FILE}")
if [[ -z "${CM_NAME}" ]]; then
    log "Lease claim file is empty. Nothing to check in."
    exit 0
fi

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "WARNING: Lease host kubeconfig not found. Cannot check in ${CM_NAME}."
    log "The controller will recover this cluster via stale lease detection."
    exit 0
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JOB_NAME="${JOB_NAME:-unknown-job}"
BUILD_ID="${BUILD_ID:-unknown-build}"
OPERATOR_NAME=$(cat "${SHARED_DIR}/lease-operator" 2>/dev/null || true)

if [[ -n "${OPERATOR_NAME}" ]]; then
    # Per-operator mode: remove this operator with CAS retry
    log "Checking in operator ${OPERATOR_NAME} from ${CM_NAME}"

    for retry in $(seq 1 5); do
        CM_JSON=$(lease_oc get configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" -o json 2>/dev/null || echo "")
        if [[ -z "${CM_JSON}" ]]; then
            log "WARNING: ConfigMap ${CM_NAME} not found. Controller will recover."
            exit 0
        fi

        CURRENT_OPS=$(echo "${CM_JSON}" | jq -r '.metadata.annotations["rosa-cluster-lease/operators"] // ""')
        NEW_OPS=$(echo "${CURRENT_OPS}" | tr ',' '\n' | grep -v "^${OPERATOR_NAME}:" | paste -sd ',' - || true)

        if [[ -z "${NEW_OPS}" ]]; then
            MODIFIED=$(echo "${CM_JSON}" | jq '
                .metadata.labels["rosa-cluster-lease/status"] = "available" |
                .metadata.annotations["rosa-cluster-lease/operators"] = "" |
                .metadata.annotations["rosa-cluster-lease/holder"] = "" |
                .metadata.annotations["rosa-cluster-lease/build-id"] = "" |
                .metadata.annotations["rosa-cluster-lease/released-at"] = "'"${RELEASED_AT}"'"
            ')
        else
            MODIFIED=$(echo "${CM_JSON}" | jq '
                .metadata.annotations["rosa-cluster-lease/operators"] = "'"${NEW_OPS}"'" |
                .metadata.annotations["rosa-cluster-lease/released-at"] = "'"${RELEASED_AT}"'"
            ')
        fi

        if echo "${MODIFIED}" | lease_oc replace -n "${LEASE_NAMESPACE}" -f - 2>/dev/null; then
            if [[ -z "${NEW_OPS}" ]]; then
                log "Operator ${OPERATOR_NAME} released. Cluster ${CM_NAME} returned to available"
            else
                log "Operator ${OPERATOR_NAME} released from ${CM_NAME}. Remaining: ${NEW_OPS}"
            fi
            break
        else
            log "Conflict on checkin attempt ${retry}, retrying..."
            sleep 1
        fi

        if [[ ${retry} -eq 5 ]]; then
            log "WARNING: Failed to check in ${CM_NAME} after 5 retries. Controller will recover it."
        fi
    done
else
    # Exclusive mode (legacy): release the whole cluster
    CURRENT_HOLDER=$(lease_oc get configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" -o json 2>/dev/null | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    if [[ -n "${CURRENT_HOLDER}" && "${CURRENT_HOLDER}" != "${JOB_NAME}" ]]; then
        log "WARNING: Lease ${CM_NAME} is held by ${CURRENT_HOLDER}, not us (${JOB_NAME}). Skipping checkin."
        exit 0
    fi

    log "Checking in lease cluster: ${CM_NAME}"

    if lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
        "metadata": {
            "labels": { "rosa-cluster-lease/status": "available" },
            "annotations": {
                "rosa-cluster-lease/holder": "",
                "rosa-cluster-lease/build-id": "",
                "rosa-cluster-lease/released-at": "'"${RELEASED_AT}"'"
            }
        }
    }'; then
        log "Cluster ${CM_NAME} returned to lease inventory"
    else
        log "WARNING: Failed to check in ${CM_NAME}. Controller will recover it."
    fi
fi
