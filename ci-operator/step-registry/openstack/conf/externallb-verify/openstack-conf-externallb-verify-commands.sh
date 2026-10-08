#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE:-}" != *"externallb"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not containing externallb."
    exit 0
fi

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

dns_records_type="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.openstack.dnsRecordsType}')"
if [[ "${dns_records_type}" != "External" ]]; then
    echo "ERROR: expected dnsRecordsType=External, got '${dns_records_type}'"
    exit 1
fi
echo "dnsRecordsType is External"

load_balancer_type="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.openstack.loadBalancer.type}')"
if [[ "${load_balancer_type}" != "UserManaged" ]]; then
    echo "ERROR: expected loadBalancer.type=UserManaged, got '${load_balancer_type}'"
    exit 1
fi
echo "loadBalancer.type is UserManaged"

# When multiple LB endpoints were provisioned, api/api-int DNS must list them all.
if [[ -f "${SHARED_DIR}/LB_HOSTS" && -f "${SHARED_DIR}/dns_up.json" ]]; then
    expected=0
    while IFS= read -r ip || [[ -n "${ip}" ]]; do
        [[ -z "${ip}" ]] && continue
        expected=$((expected + 1))
    done < "${SHARED_DIR}/LB_HOSTS"

    if [[ "${expected}" -lt 1 ]]; then
        echo "ERROR: LB_HOSTS is empty"
        exit 1
    fi

    for name_prefix in api api-int; do
        count="$(jq --arg p "${name_prefix}." \
            '[.Changes[].ResourceRecordSet | select(.Name | startswith($p)) | .ResourceRecords | length] | first // 0' \
            "${SHARED_DIR}/dns_up.json")"
        values="$(jq -r --arg p "${name_prefix}." \
            '.Changes[].ResourceRecordSet | select(.Name | startswith($p)) | .ResourceRecords[].Value' \
            "${SHARED_DIR}/dns_up.json" | tr '\n' ' ')"
        echo "${name_prefix} DNS has ${count} address(es): ${values}"
        if [[ "${count}" -lt "${expected}" ]]; then
            echo "ERROR: expected at least ${expected} addresses for ${name_prefix}, got ${count}"
            exit 1
        fi
    done
    echo "api/api-int DNS records include ${expected} LB endpoint(s)"
fi
