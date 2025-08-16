#!/usr/bin/env bash
set -euo pipefail

# ====== UTIL ======
log()   { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
fail()  { error "$*"; exit 1; }

# ====== CHECK: Disabled Capability ======
is_disabled_capability() {
    local component="$1"
    local status_caps spec_caps

    status_caps=$(oc get clusterversion -o=jsonpath='{.items[*].status.capabilities.enabledCapabilities}')
    spec_caps=$(oc get clusterversion -o=jsonpath='{.items[*].spec.capabilities.additionalEnabledCapabilities}')

    log "Cluster enabled capabilities (status): $status_caps"
    log "Additional enabled capabilities (spec): $spec_caps"

    local enabled_caps
    enabled_caps="$(echo "$status_caps $spec_caps" | tr ' ' '\n' | tr '[:upper:]' '[:lower:]')"

    if echo "$enabled_caps" | grep -qw "$(echo "$component" | tr '[:upper:]' '[:lower:]')"; then
        return 1
    fi
    return 0
}

get_disabled_capabilities() {
    local disabled_caps=""

    if [[ -n "${HC_DISABLED_CAPS:-}" ]]; then
        disabled_caps="$HC_DISABLED_CAPS"
    fi

    echo "$disabled_caps" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | sed '/^$/d'
}

check_disabled_capability() {
    mapfile -t caps < <(get_disabled_capabilities)
    if [[ ${#caps[@]} -eq 0 ]]; then
        fail "No disabled capabilities found. Please check the ENV var: HC_DISABLED_CAPS."
    fi

    for cap in "${caps[@]}"; do
        if ! is_disabled_capability "$cap"; then
            fail "Capability \"$cap\" is not disabled — still enabled in cluster."
        fi
        log "Disabled capability confirmed: $cap"
    done    
}

# ====== CHECK: ClusterOperators ======
check_cluster_operators() {
    local failed_co=false

    # Iterate over cluster operators
    while read -r name available progressing degraded; do
        [[ "$available" == "True" ]] || { warn "ClusterOperator $name is not Available"; failed_co=true; }
        [[ "$progressing" == "False" ]] || { warn "ClusterOperator $name is still Progressing"; failed_co=true; }
        [[ "$degraded" == "False" ]] || { warn "ClusterOperator $name is Degraded"; failed_co=true; }
    done < <(oc get co -o custom-columns=NAME:.metadata.name,AVAILABLE:'{.status.conditions[?(@.type=="Available")].status}',PROGRESSING:'{.status.conditions[?(@.type=="Progressing")].status}',DEGRADED:'{.status.conditions[?(@.type=="Degraded")].status}' --no-headers)
    oc get co
    if [[ "$failed_co" == true ]]; then
        fail "One or more ClusterOperators are not healthy."
    fi
    log "✅ All ClusterOperators are healthy."
}

# ====== CHECK: Hypershift Hosted Cluster Health ======
check_hosted_cluster_health() {
    log "Checking nodes ..."
    if oc get nodes --no-headers | grep -v " Ready "; then
        fail "One or more nodes are not Ready."
    fi
    log "✅ All nodes are Ready."

    log "Checking ClusterOperators ..."
    check_cluster_operators

    log "Checking API /healthz ..."
    if ! oc get --raw /healthz &>/dev/null; then
        fail "API healthz endpoint is not healthy."
    fi
    log "✅ API /healthz OK."
}

# ====== MAIN ======
log "Starting disabled capability checking ..."
check_disabled_capability
log "✅ Disabled capabilities checking passed."
log "----------------------------------------"

log "Starting Hypershift Hosted Cluster health checks ..."
check_hosted_cluster_health
log "✅ All health checks passed."
log "----------------------------------------"