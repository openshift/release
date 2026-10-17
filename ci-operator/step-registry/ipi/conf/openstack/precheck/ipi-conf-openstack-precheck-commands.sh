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
    local BASE_DOMAIN=$3
    local WAIT_TIME=$4
    local TRY_COUNT=$5

    for name in "${!ipmap[@]}"; do
        local ip=${ipmap[$name]}
        for try in $(seq 1 $TRY_COUNT); do
            echo "Attempt $try to verify we can resolve $name.$cluster_name.$BASE_DOMAIN"
            if check_ip_resolves "$ip" "$name.$cluster_name.$BASE_DOMAIN"; then
                echo "$name.$cluster_name.$BASE_DOMAIN resolves correctly to $ip"
                break
            fi

            if [[ $try -eq $TRY_COUNT ]]; then
                echo "FAILED: After $TRY_COUNT tries, $name.$cluster_name.$BASE_DOMAIN did not resolve to $ip"
                exit 1
            fi

            sleep $WAIT_TIME
        done
    done
}

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
API_IP=$(<"${SHARED_DIR}/API_IP")
INGRESS_IP=$(<"${SHARED_DIR}/INGRESS_IP")

declare -A ipmap=(
    ["api"]=$API_IP
    ["ingress.apps"]=$INGRESS_IP
)

# Match dnsrecords: only non-proxy externallb publishes api+ingress as LB_HOST.
# proxy-externallb keeps api/ingress -> VIPs; do not key off LB_HOST alone
# because bastionproxy always writes it for proxy jobs too.
# CONFIG_TYPE must be declared in this step's ref.yaml or it is unset here.
if [[ "${CONFIG_TYPE:-}" == *"externallb"* && "${CONFIG_TYPE:-}" != *"proxy"* && -f "${SHARED_DIR}/LB_HOST" ]]; then
    LB_HOST=$(<"${SHARED_DIR}/LB_HOST")
    ipmap["api"]="${LB_HOST}"
    ipmap["ingress.apps"]="${LB_HOST}"
    echo "precheck: CONFIG_TYPE='${CONFIG_TYPE}' -> expecting api + ingress.apps -> ${LB_HOST} (LB_HOST)"
else
    echo "precheck: CONFIG_TYPE='${CONFIG_TYPE:-}' -> expecting api -> ${API_IP}, ingress.apps -> ${INGRESS_IP}"
fi

if [[ "${CONFIG_TYPE:-}" == *"externallb"* ]]; then
    ipmap["api-int"]=$API_IP
fi

verify_resolution "$CLUSTER_NAME" ipmap "$BASE_DOMAIN" "$WAIT_TIME" "$TRY_COUNT"

if [[ -s "${SHARED_DIR}/HIVE_FIP_API" && -s "${SHARED_DIR}/HIVE_FIP_INGRESS" && -s "${SHARED_DIR}/HIVE_CLUSTER_NAME" ]]; then
    HIVE_FIP_API=$(<"${SHARED_DIR}/HIVE_FIP_API")
    HIVE_FIP_INGRESS=$(<"${SHARED_DIR}/HIVE_FIP_INGRESS")
    HIVE_CLUSTER_NAME=$(<"${SHARED_DIR}/HIVE_CLUSTER_NAME")

    # shellcheck disable=SC2034
    declare -A ipmap_hive=(
        ["api"]=$HIVE_FIP_API
        ["ingress.apps"]=$HIVE_FIP_INGRESS
    )

    verify_resolution "$HIVE_CLUSTER_NAME" ipmap_hive "$BASE_DOMAIN" "$WAIT_TIME" "$TRY_COUNT"
fi
