#!/bin/bash

suffix=$(cat /dev/urandom | tr -dc "a-z0-9" | head -c 5)

log() {
    echo "$(date --iso-8601=seconds)   ${1}"
}

checkoutCluster() {
    local cluster_type="${1}"
    local cluster_idx="${2}"
    local pool_filter="${3}"

    local cluster_claim=""
    local tmp_claim="${cluster_type}-${cluster_idx}-${suffix}"
    local filtered_pools=""
    filtered_pools="$(echo "${pools}" | grep -e "${pool_filter}")"
    # Adding the claim name to the ClusterClaim file up front in case this
    # script gets cancelled early so that the checkin job can handle cleanup.
    echo "${tmp_claim}" >>"${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"

    for pool in ${filtered_pools}; do
        log "Provisioning claim ${tmp_claim} from ClusterPool ${pool} ..."

        make clusterpool/checkout \
            CLUSTERPOOL_NAME="${pool}" \
            CLUSTERPOOL_CLUSTER_CLAIM="${tmp_claim}" 2>&1 |
            sed -u "s/^/${tmp_claim}   /" |
            tee "${ARTIFACT_DIR}/${pool}_${tmp_claim}.log"

        if [[ "${PIPESTATUS[0]}" == 0 ]]; then
            cluster_claim="${tmp_claim}"
            break
        fi

        log "Claim ${tmp_claim} from ClusterPool ${pool} failed."
    done

    if [[ -z "${cluster_claim}" ]]; then
        log "No cluster was checked out for ${cluster_type} ${cluster_idx}. Tried these cluster pools:"
        echo "${filtered_pools}"
        return 1
    fi
}

temp=$(mktemp -d -t ocm-XXXXX)
cd "${temp}" || exit 1

cp "${MAKEFILE}" ./Makefile

log "Starting cluster provisioning ..."

pools=""
if [[ -n "$CLUSTERPOOL_LIST" ]]; then
    pools=$(echo "$CLUSTERPOOL_LIST" | tr "," "\n")
elif [[ -f "${SHARED_DIR}/${CLUSTERPOOL_LIST_FILE}" ]]; then
    pools=$(cat "${SHARED_DIR}/${CLUSTERPOOL_LIST_FILE}")
fi

if [[ -z "$pools" ]]; then
    log "No pools specified by CLUSTERPOOL_LIST or CLUSTERPOOL_LIST_FILE"
    exit 1
fi

pids=()

# Checkout hub clusters
log "Provisioning ${CLUSTERPOOL_HUB_COUNT} hub clusters ..."
if [[ -n "${CLUSTERPOOL_HUB_FILTER}" ]]; then
    log "Filtering ClusterPool list using filter: '${CLUSTERPOOL_HUB_FILTER}' ..."
fi

for ((i = 1; i <= CLUSTERPOOL_HUB_COUNT; i++)); do
    checkoutCluster hub ${i} "${CLUSTERPOOL_HUB_FILTER}" &
    pids+=($!)
    sleep 60
done

# Checkout managed clusters
log "Provisioning ${CLUSTERPOOL_MANAGED_COUNT} managed clusters ..."
if [[ -n "${CLUSTERPOOL_MANAGED_FILTER}" ]]; then
    log "Filtering ClusterPool list using filter: '${CLUSTERPOOL_MANAGED_FILTER}' ..."
fi

for ((i = 1; i <= CLUSTERPOOL_MANAGED_COUNT; i++)); do
    checkoutCluster managed ${i} "${CLUSTERPOOL_MANAGED_FILTER}" &
    pids+=($!)
    sleep 60
done

# Wait for background processes to complete and collect exit codes
exit_code=0

for pid in "${pids[@]}"; do
    wait ${pid} || exit_code=$?
done

if [[ "${exit_code}" != 0 ]]; then
    log "error: claim provisioning failed"
    exit ${exit_code}
fi

log "Cluster claims:"
cat "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"
