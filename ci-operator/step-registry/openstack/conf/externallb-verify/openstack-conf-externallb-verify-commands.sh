#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

verify_externallb=false
if [[ "${CONFIG_TYPE:-}" == *"externallb"* ]]; then
    verify_externallb=true
fi

# Run for externallb topologies, or when MCS api-int verification is explicitly enabled
# (e.g. standard IPI on releases where UserManaged/externallb is unavailable).
if [[ "${verify_externallb}" != "true" && "${VERIFY_MCS_API_INT:-}" != "true" ]]; then
    echo "Skipping step (CONFIG_TYPE does not contain externallb and VERIFY_MCS_API_INT!=true)."
    exit 0
fi

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ "${verify_externallb}" == "true" ]]; then
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

    # Multi-LB (#86644): when LB_HOSTS is present, api DNS must list those FIPs;
    # api-int must still point at the machines-net API VIP.
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

    # Outside probe: in-cluster hairpin to these FIPs is unavailable on some clouds.
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
fi

# OCPBUGS-112483: optional MCS/Ignition api-int check (enable on payloads that include the fix).
if [[ "${VERIFY_MCS_API_INT:-}" != "true" ]]; then
    echo "Skipping MCS api-int Ignition check (set VERIFY_MCS_API_INT=true to enable)."
    exit 0
fi

base_domain="$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
api_vip="$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.openstack.apiServerInternalIPs[0]}')"

user_data=""
for secret in worker-user-data worker-user-data-managed; do
    if oc -n openshift-machine-api get "secret/${secret}" >/dev/null 2>&1; then
        user_data="$(oc -n openshift-machine-api get "secret/${secret}" -o jsonpath='{.data.userData}' | base64 -d)"
        if [[ -n "${user_data}" ]]; then
            echo "Checking MCS Ignition URL in secret/${secret}"
            break
        fi
    fi
done
if [[ -z "${user_data}" ]]; then
    echo "ERROR: could not read worker-user-data secret userData"
    exit 1
fi

mcs_urls="$(printf '%s' "${user_data}" | grep -oE 'https://[^"[:space:]]+:22623[^"[:space:]]*' || true)"
if [[ -z "${mcs_urls}" ]]; then
    echo "ERROR: no MCS URL (:22623) found in worker user-data"
    exit 1
fi
echo "Found MCS URL(s):"
printf '%s\n' "${mcs_urls}"

if ! printf '%s\n' "${mcs_urls}" | grep -q "api-int\."; then
    echo "ERROR: expected MCS URL host to use api-int.<cluster>.<domain> (OCPBUGS-112483)"
    exit 1
fi
if [[ -n "${api_vip}" ]] && printf '%s\n' "${mcs_urls}" | grep -qF "https://${api_vip}:22623"; then
    echo "ERROR: MCS URL still uses API VIP ${api_vip}:22623; expected api-int FQDN"
    exit 1
fi
if [[ -n "${base_domain}" ]] && ! printf '%s\n' "${mcs_urls}" | grep -qF ".${base_domain}:22623"; then
    echo "ERROR: MCS URL does not reference base domain ${base_domain}"
    exit 1
fi
echo "MCS Ignition endpoint uses api-int FQDN (OCPBUGS-112483)"
