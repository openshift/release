#!/bin/bash
set -uo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

DIAG_DIR="${ARTIFACT_DIR}/dns-diag"
mkdir -p "${DIAG_DIR}"

log "=== CoreDNS Diagnostics ==="

log "CoreDNS pod status:"
oc get pods -n openshift-dns -o wide 2>&1 | tee "${DIAG_DIR}/dns-pods.txt"

log "CoreDNS pod restart counts:"
oc get pods -n openshift-dns \
    -o jsonpath='{range .items[*]}{.metadata.name}  restarts={.status.containerStatuses[0].restartCount}  node={.spec.nodeName}{"\n"}{end}' \
    2>&1 | tee "${DIAG_DIR}/dns-restarts.txt"

log "DNS operator status:"
oc get co dns -o yaml 2>&1 > "${DIAG_DIR}/dns-operator.yaml"
oc get co dns 2>&1 | tee -a "${DIAG_DIR}/dns-pods.txt"

log "CoreDNS logs (last 200 lines):"
oc logs -n openshift-dns --selector dns.operator/daemonset-dns=default \
    --tail=200 --timestamps 2>&1 > "${DIAG_DIR}/dns-logs.txt"

log "CoreDNS configmap:"
oc get configmap dns-default -n openshift-dns -o yaml 2>&1 > "${DIAG_DIR}/dns-configmap.yaml"

log "Node and MCP status:"
oc get nodes 2>&1 | tee "${DIAG_DIR}/nodes.txt"
oc get mcp 2>&1 | tee "${DIAG_DIR}/mcp.txt"

API_HOST=$(oc whoami --show-server 2>/dev/null | sed 's|https://||;s|:.*||')
log "API server hostname: ${API_HOST}"

log "DNS resolution test:"
if command -v dig &>/dev/null; then
    log "Using dig"
    dig "${API_HOST}" @172.30.0.10 2>&1 | tee "${DIAG_DIR}/dns-resolve-udp.txt"
    dig "${API_HOST}" @172.30.0.10 +tcp 2>&1 | tee "${DIAG_DIR}/dns-resolve-tcp.txt"
elif command -v nslookup &>/dev/null; then
    log "Using nslookup"
    nslookup "${API_HOST}" 172.30.0.10 2>&1 | tee "${DIAG_DIR}/dns-resolve.txt"
elif command -v getent &>/dev/null; then
    log "Using getent"
    getent hosts "${API_HOST}" 2>&1 | tee "${DIAG_DIR}/dns-resolve.txt"
elif command -v python3 &>/dev/null; then
    log "Using python3 socket.getaddrinfo"
    python3 -c "import socket; print(socket.getaddrinfo('${API_HOST}', 6443))" 2>&1 | tee "${DIAG_DIR}/dns-resolve.txt"
else
    log "WARNING: No DNS lookup tools available (tried dig, nslookup, getent, python3). Cannot test resolution directly."
fi

log "DNS service status:"
oc get svc -n openshift-dns dns-default -o wide 2>&1 | tee "${DIAG_DIR}/dns-svc.txt"

log "=== Diagnostics complete ==="
