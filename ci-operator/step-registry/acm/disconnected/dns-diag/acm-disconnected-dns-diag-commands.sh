#!/bin/bash
set -uo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

DIAG_DIR="${ARTIFACT_DIR}/dns-diag"
mkdir -p "${DIAG_DIR}"

log "=== CoreDNS Diagnostics (no oc dependency) ==="

API_HOST=$(grep -m1 'server:' "${SHARED_DIR}/kubeconfig" | sed 's|.*https://||;s|:.*||')
log "API server hostname: ${API_HOST}"

log "resolv.conf:"
cat /etc/resolv.conf 2>&1 | tee "${DIAG_DIR}/resolv.conf.txt"

DNS_SERVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
log "Primary nameserver: ${DNS_SERVER}"

dns_lookup() {
    local label="$1"
    local host="$2"
    local server="${3:-}"
    log "DNS lookup (${label}): ${host}"
    if command -v dig &>/dev/null; then
        if [[ -n "${server}" ]]; then
            dig "${host}" "@${server}" 2>&1 | tee "${DIAG_DIR}/resolve-${label}.txt"
        else
            dig "${host}" 2>&1 | tee "${DIAG_DIR}/resolve-${label}.txt"
        fi
    elif command -v nslookup &>/dev/null; then
        if [[ -n "${server}" ]]; then
            nslookup "${host}" "${server}" 2>&1 | tee "${DIAG_DIR}/resolve-${label}.txt"
        else
            nslookup "${host}" 2>&1 | tee "${DIAG_DIR}/resolve-${label}.txt"
        fi
    elif command -v getent &>/dev/null; then
        getent hosts "${host}" 2>&1 | tee "${DIAG_DIR}/resolve-${label}.txt"
    elif command -v python3 &>/dev/null; then
        python3 -I -c "import socket; print(socket.getaddrinfo('${host}', 6443))" 2>&1 | tee "${DIAG_DIR}/resolve-${label}.txt"
    else
        log "WARNING: No DNS lookup tools available (tried dig, nslookup, getent, python3)"
        return 1
    fi
}

# Resolve the API hostname
dns_lookup "api" "${API_HOST}" "${DNS_SERVER}"

# Control: resolve the base domain to check if DNS works for the zone in general
BASE_DOMAIN=$(echo "${API_HOST}" | sed 's/^api\.//')
log "Control lookup (base domain ${BASE_DOMAIN}):"
dns_lookup "control-base" "${BASE_DOMAIN}" "${DNS_SERVER}"

# SOA record shows negative cache TTL
if command -v dig &>/dev/null; then
    ZONE=$(echo "${API_HOST}" | cut -d. -f3-)
    log "SOA for ${ZONE} (shows negative cache TTL):"
    dig SOA "${ZONE}" "@${DNS_SERVER}" 2>&1 | tee "${DIAG_DIR}/resolve-soa.txt"
fi

# Try HTTPS directly — curl may resolve independently
log "Direct HTTPS to API /healthz:"
curl -sk --connect-timeout 10 "https://${API_HOST}:6443/healthz" 2>&1 | tee "${DIAG_DIR}/api-healthz.txt"
log "curl exit code: $?"

# Poll DNS to see if negative cache expires
log "Polling DNS resolution every 30s for 5 minutes:"
for i in $(seq 1 10); do
    ts=$(date -u +%H:%M:%S)
    if command -v dig &>/dev/null; then
        result=$(dig +short "${API_HOST}" "@${DNS_SERVER}" 2>&1)
    elif command -v nslookup &>/dev/null; then
        result=$(nslookup "${API_HOST}" "${DNS_SERVER}" 2>&1 | awk '/^Address: / {print $2}')
    elif command -v getent &>/dev/null; then
        result=$(getent hosts "${API_HOST}" 2>&1 | awk '{print $1}')
    else
        result=$(python3 -I -c "import socket; print(socket.getaddrinfo('${API_HOST}', 6443)[0][4][0])" 2>&1)
    fi
    echo "${ts} attempt=${i} result=${result}" | tee -a "${DIAG_DIR}/resolve-poll.txt"
    if [[ -n "${result}" && "${result}" != *"NXDOMAIN"* && "${result}" != *"not found"* && "${result}" != *"error"* && "${result}" != *"SERVFAIL"* ]]; then
        log "DNS resolution recovered on attempt ${i}"
        break
    fi
    sleep 30
done

log "=== Diagnostics complete ==="
