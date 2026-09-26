#!/bin/bash

set -euo pipefail

capres_rg_file="${SHARED_DIR}/capacity_reservation_rg"
crg_name_file="${SHARED_DIR}/capacity_reservation_group_name"
control_plane_cr_file="${SHARED_DIR}/capacity_reservation_control_plane_name"
compute_cr_file="${SHARED_DIR}/capacity_reservation_compute_name"

for file in "${capres_rg_file}" "${crg_name_file}" "${control_plane_cr_file}" "${compute_cr_file}"; do
    if [[ ! -s "${file}" ]]; then
        echo "Required file ${file} not found or empty" >&2
        exit 1
    fi
done

CAPRES_RG=$(< "${capres_rg_file}")
CRG_NAME=$(< "${crg_name_file}")
CONTROL_PLANE_CR_NAME=$(< "${control_plane_cr_file}")
COMPUTE_CR_NAME=$(< "${compute_cr_file}")

command -v az
az --version
command -v oc

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

node_provider_ids() {
    local role="$1"

    oc get nodes -l "node-role.kubernetes.io/${role}" -o json |
        jq -r '.items[].spec.providerID | select(startswith("azure://")) | sub("^azure://"; "")' |
        tr '[:upper:]' '[:lower:]' |
        sort -u
}

node_provider_ids master > "${workdir}/expected-control-plane"
node_provider_ids worker > "${workdir}/expected-compute"

control_plane_count="$(wc -l < "${workdir}/expected-control-plane" | tr -d ' ')"
compute_count="$(wc -l < "${workdir}/expected-compute" | tr -d ' ')"

if [[ "${control_plane_count}" -ne "${EXPECTED_CONTROL_PLANE_VM_COUNT}" ]]; then
    echo "Expected ${EXPECTED_CONTROL_PLANE_VM_COUNT} control-plane VM IDs, found ${control_plane_count}" >&2
    cat "${workdir}/expected-control-plane" >&2
    exit 1
fi
if [[ "${compute_count}" -ne "${EXPECTED_COMPUTE_VM_COUNT}" ]]; then
    echo "Expected ${EXPECTED_COMPUTE_VM_COUNT} compute VM IDs, found ${compute_count}" >&2
    cat "${workdir}/expected-compute" >&2
    exit 1
fi

validate_associations() {
    local reservation_name="$1"
    local role="$2"
    local expected_file="$3"
    local actual_file="${workdir}/actual-${role}"

    for attempt in {1..10}; do
        if az capacity reservation show \
            --resource-group "${CAPRES_RG}" \
            --capacity-reservation-group "${CRG_NAME}" \
            --capacity-reservation-name "${reservation_name}" \
            --instance-view \
            --query 'instanceView.utilizationInfo.virtualMachinesAllocated[].id' \
            --output tsv |
            tr '[:upper:]' '[:lower:]' |
            sort -u > "${actual_file}" &&
            cmp -s "${expected_file}" "${actual_file}"; then
            echo "Validated ${role} VM associations with capacity reservation ${reservation_name}"
            return 0
        fi

        echo "Capacity reservation ${reservation_name} does not yet contain the expected ${role} VM IDs (attempt ${attempt}/10)" >&2
        echo "Expected:" >&2
        cat "${expected_file}" >&2
        echo "Actual:" >&2
        cat "${actual_file}" >&2
        if [[ "${attempt}" -lt 10 ]]; then
            sleep 30
        fi
    done

    echo "Capacity reservation ${reservation_name} is missing expected ${role} VM associations" >&2
    return 1
}

validate_associations "${CONTROL_PLANE_CR_NAME}" control-plane "${workdir}/expected-control-plane"
validate_associations "${COMPUTE_CR_NAME}" compute "${workdir}/expected-compute"
