#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

function check_ips_resolve() {
    local domain=$1
    shift
    local expected_ips=("$@")

    local lookup
    lookup=$(nslookup "$domain" 2>/dev/null) || true
    if [[ -z "${lookup}" ]]; then
        echo "$domain did not resolve"
        return 1
    fi
    # Exact Address tokens after Name: (IPv6-safe; bind-utils / busybox).
    local answers
    answers="$(awk '
        /^Name:/{ in_answer=1; next }
        in_answer && /^Address/ {
            line = $0
            sub(/^Address(es)?[ \t]*[0-9]*:[ \t]*/, "", line)
            gsub(/#.*/, "", line)
            n = split(line, a, /[ \t]+/)
            if (n >= 1 && a[1] != "") print a[1]
        }
    ' <<<"${lookup}")"
    for ip in "${expected_ips[@]}"; do
        if ! grep -Fxq "${ip}" <<<"${answers}"; then
            echo "$domain does not resolve to $ip"
            echo "nslookup output:"
            echo "${lookup}"
            return 1
        fi
    done
    echo "$domain resolves to ${expected_ips[*]}"
    return 0
}

function verify_name() {
    local cluster_name=$1
    local name=$2
    shift 2
    local expected_ips=("$@")
    local domain="${name}.${cluster_name}.${BASE_DOMAIN}"

    for try in $(seq 1 "$TRY_COUNT"); do
        echo "Attempt $try to verify we can resolve $domain (expect ${expected_ips[*]})"
        if check_ips_resolve "$domain" "${expected_ips[@]}"; then
            echo "$domain resolves correctly"
            return 0
        fi

        if [[ $try -eq $TRY_COUNT ]]; then
            echo "FAILED: After $TRY_COUNT tries, $domain did not resolve to ${expected_ips[*]}"
            exit 1
        fi

        sleep "$WAIT_TIME"
    done
}

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
API_IP=$(<"${SHARED_DIR}/API_IP")
INGRESS_IP=$(<"${SHARED_DIR}/INGRESS_IP")

# LB_HOSTS (multi-LB FIPs) when present; otherwise API_IP.
API_IPS=()
if [[ -f "${SHARED_DIR}/LB_HOSTS" ]]; then
    while IFS= read -r ip || [[ -n "${ip}" ]]; do
        [[ -z "${ip}" ]] && continue
        API_IPS+=("${ip}")
    done < "${SHARED_DIR}/LB_HOSTS"
fi
if [[ "${#API_IPS[@]}" -eq 0 ]]; then
    API_IPS+=("${API_IP}")
fi

verify_name "$CLUSTER_NAME" "api" "${API_IPS[@]}"
verify_name "$CLUSTER_NAME" "ingress.apps" "$INGRESS_IP"
if [[ "${CONFIG_TYPE:-}" == *"externallb"* || -f "${SHARED_DIR}/LB_HOSTS" ]]; then
    verify_name "$CLUSTER_NAME" "api-int" "${API_IP}"
fi

if [[ -s "${SHARED_DIR}/HIVE_FIP_API" && -s "${SHARED_DIR}/HIVE_FIP_INGRESS" && -s "${SHARED_DIR}/HIVE_CLUSTER_NAME" ]]; then
    HIVE_FIP_API=$(<"${SHARED_DIR}/HIVE_FIP_API")
    HIVE_FIP_INGRESS=$(<"${SHARED_DIR}/HIVE_FIP_INGRESS")
    HIVE_CLUSTER_NAME=$(<"${SHARED_DIR}/HIVE_CLUSTER_NAME")

    verify_name "$HIVE_CLUSTER_NAME" "api" "$HIVE_FIP_API"
    verify_name "$HIVE_CLUSTER_NAME" "ingress.apps" "$HIVE_FIP_INGRESS"
fi
