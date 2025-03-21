#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

function check_ip_resolves() {
    local ip=$1
    local domain=$2

    local lookup
    lookup=$(nslookup "$domain" 2>/dev/null)
    if [[ $? -eq 0 ]] && [[ ${lookup} =~ $ip ]]; then
        echo "$domain resolves to $ip"
        return 0
    else
        echo "$domain does not resolve to $ip"
        return 1
    fi
}

function verify_resolution() {
    local cluster_name=$1
    declare -n ipmap=$2
    local base_domain=$3
    local sleep_time=$4
    local try_count=$5

    for name in "${!ipmap[@]}"; do
        local ip=${ipmap[$name]}
        for try in $(seq 1 $try_count); do
            echo "Attempt $try to verify we can resolve $name.$cluster_name.$base_domain"
            if check_ip_resolves "$ip" "$name.$cluster_name.$base_domain"; then
                echo "$name.$cluster_name.$base_domain resolves correctly to $ip"
                break
            fi
            sleep $sleep_time

            if [[ $try -eq $try_count ]]; then
                echo "FAILED: After $try_count tries, $name.$cluster_name.$base_domain did not resolve to $ip"
                exit 1
            fi
        done
    done
}

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
API_IP=$(<"${SHARED_DIR}/API_IP")
INGRESS_IP=$(<"${SHARED_DIR}/INGRESS_IP")
SLEEP_TIME=${WAIT_TIME}
TRY_COUNT=${TRY_COUNT}
BASE_DOMAIN=${BASE_DOMAIN}

declare -A ipmap=(
    ["api"]=$API_IP
    ["ingress.apps"]=$INGRESS_IP
)

verify_resolution "$CLUSTER_NAME" ipmap "$BASE_DOMAIN" "$SLEEP_TIME" "$TRY_COUNT"

if [[ -f "${SHARED_DIR}/HIVE_FIP_API" && -f "${SHARED_DIR}/HIVE_FIP_INGRESS" ]]; then
    HIVE_FIP_API=$(<"${SHARED_DIR}/HIVE_FIP_API")
    HIVE_FIP_INGRESS=$(<"${SHARED_DIR}/HIVE_FIP_INGRESS")
    HIVE_CLUSTER_NAME=$(<"${SHARED_DIR}/HIVE_CLUSTER_NAME")

    # shellcheck disable=SC2034
    declare -A ipmap_hive=(
        ["api"]=$HIVE_FIP_API
        ["ingress.apps"]=$HIVE_FIP_INGRESS
    )

    verify_resolution "$HIVE_CLUSTER_NAME" ipmap_hive "$BASE_DOMAIN" "$SLEEP_TIME" "$TRY_COUNT"
fi