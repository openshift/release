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

# api → multi LB FIPs; api-int → machines-net API VIP (see dnsrecords step).
if [[ -f "${SHARED_DIR}/dns_up.json" ]]; then
    if [[ -f "${SHARED_DIR}/LB_HOSTS" ]]; then
        expected=0
        while IFS= read -r ip || [[ -n "${ip}" ]]; do
            [[ -z "${ip}" ]] && continue
            expected=$((expected + 1))
        done < "${SHARED_DIR}/LB_HOSTS"

        if [[ "${expected}" -lt 1 ]]; then
            echo "ERROR: LB_HOSTS is empty"
            exit 1
        fi

        api_count="$(jq '[.Changes[].ResourceRecordSet | select(.Name | startswith("api.")) | .ResourceRecords | length] | first // 0' \
            "${SHARED_DIR}/dns_up.json")"
        api_values="$(jq -r '.Changes[].ResourceRecordSet | select(.Name | startswith("api.")) | .ResourceRecords[].Value' \
            "${SHARED_DIR}/dns_up.json" | tr '\n' ' ')"
        echo "api DNS has ${api_count} address(es): ${api_values}"
        if [[ "${api_count}" -lt "${expected}" ]]; then
            echo "ERROR: expected at least ${expected} addresses for api, got ${api_count}"
            exit 1
        fi
        echo "api DNS records include ${expected} LB endpoint(s)"
    fi

    if [[ -f "${SHARED_DIR}/API_IP" ]]; then
        api_ip="$(<"${SHARED_DIR}/API_IP")"
        api_int_values="$(jq -r '.Changes[].ResourceRecordSet | select(.Name | startswith("api-int.")) | .ResourceRecords[].Value' \
            "${SHARED_DIR}/dns_up.json")"
        echo "api-int DNS address(es): ${api_int_values}"
        if ! grep -Fxq "${api_ip}" <<<"${api_int_values}"; then
            echo "ERROR: expected api-int to include API VIP ${api_ip}"
            exit 1
        fi
        echo "api-int DNS includes API VIP ${api_ip}"
    fi
fi
