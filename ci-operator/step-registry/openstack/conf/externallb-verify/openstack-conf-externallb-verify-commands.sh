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
            "${SHARED_DIR}/dns_up.json")"
        echo "api DNS has ${api_count} address(es): ${api_values//$'\n'/ }"
        if [[ "${api_count}" -lt "${expected}" ]]; then
            echo "ERROR: expected at least ${expected} addresses for api, got ${api_count}"
            exit 1
        fi
        while IFS= read -r ip || [[ -n "${ip}" ]]; do
            [[ -z "${ip}" ]] && continue
            if ! grep -Fxq "${ip}" <<<"${api_values}"; then
                echo "ERROR: expected api DNS to include LB endpoint ${ip}"
                exit 1
            fi
        done < "${SHARED_DIR}/LB_HOSTS"
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

# Outside probe: in-cluster hairpin to these FIPs is unavailable on this cloud.
lb_hosts=()
if [[ -f "${SHARED_DIR}/LB_HOSTS" ]]; then
    while IFS= read -r ip || [[ -n "${ip}" ]]; do
        [[ -z "${ip}" ]] && continue
        lb_hosts+=("${ip}")
    done < "${SHARED_DIR}/LB_HOSTS"
elif [[ -f "${SHARED_DIR}/LB_HOST" ]]; then
    lb_hosts+=("$(<"${SHARED_DIR}/LB_HOST")")
fi
if [[ "${#lb_hosts[@]}" -eq 0 ]]; then
    echo "ERROR: no LB_HOSTS/LB_HOST to probe"
    exit 1
fi
for ip in "${lb_hosts[@]}"; do
    echo "Checking https://${ip}:6443/readyz"
    # Ignore proxy-conf; require direct CI→FIP:6443.
    if ! curl --noproxy '*' -kfsS --connect-timeout 10 --max-time 30 "https://${ip}:6443/readyz" -o /dev/null; then
        echo "ERROR: UserManaged LB ${ip}:6443 is not reachable from CI"
        exit 1
    fi
    echo "LB endpoint ${ip}:6443 is reachable"
done
