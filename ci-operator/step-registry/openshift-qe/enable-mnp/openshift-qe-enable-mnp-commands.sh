#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Enabling Multi-Network Policy support"
echo "====================================="

# Function for logging with timestamps
log_info() { echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"; }
log_success() { echo "$(date +'%Y-%m-%d %H:%M:%S') [SUCCESS] $1"; }
log_warning() { echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $1"; }
log_error() { echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1"; }

# Check if oc is available
if ! command -v oc >/dev/null 2>&1; then
    log_error "OpenShift CLI (oc) not found"
    exit 1
fi

# Check cluster connectivity
if ! oc whoami >/dev/null 2>&1; then
    log_error "Cannot connect to OpenShift cluster"
    exit 1
fi

log_info "Cluster: $(oc whoami --show-server)"

# Check current MNP status
log_info "Checking current Multi-Network Policy status..."
current_status=$(oc get network.operator.openshift.io cluster -o jsonpath='{.spec.useMultiNetworkPolicy}' 2>/dev/null || echo "false")
log_info "Current useMultiNetworkPolicy: $current_status"

if [[ "$current_status" == "true" ]]; then
    log_success "Multi-Network Policy is already enabled"
else
    log_info "Enabling Multi-Network Policy..."
    
    # Enable Multi-Network Policy
    if oc patch network.operator.openshift.io cluster --type=merge -p '{"spec":{"useMultiNetworkPolicy":true}}'; then
        log_success "Multi-Network Policy enabled successfully"
    else
        log_error "Failed to enable Multi-Network Policy"
        exit 1
    fi
    
    # Wait for the configuration to be applied
    log_info "Waiting for Multi-Network Policy configuration to be applied..."
    for attempt in {1..30}; do
        sleep 10
        updated_status=$(oc get network.operator.openshift.io cluster -o jsonpath='{.spec.useMultiNetworkPolicy}' 2>/dev/null || echo "false")
        
        if [[ "$updated_status" == "true" ]]; then
            log_success "Multi-Network Policy configuration confirmed active"
            break
        fi
        
        log_info "Attempt $attempt/30: Waiting for configuration to be applied..."
        
        if [[ $attempt -eq 30 ]]; then
            log_error "Timeout waiting for Multi-Network Policy configuration"
            exit 1
        fi
    done
fi

# Wait for MultiNetworkPolicy CRD to be available
log_info "Waiting for MultiNetworkPolicy CRD to be available..."
for attempt in {1..60}; do
    if oc api-resources | grep -q "multi-networkpolicies"; then
        log_success "MultiNetworkPolicy CRD is available"
        break
    fi
    
    log_info "Attempt $attempt/60: Waiting for CRD to be installed..."
    sleep 10
    
    if [[ $attempt -eq 60 ]]; then
        log_error "Timeout waiting for MultiNetworkPolicy CRD"
        log_error "Available network-related resources:"
        oc api-resources | grep -i network || true
        exit 1
    fi
done

# Verify the CRD is properly installed
log_info "Verifying MultiNetworkPolicy CRD details..."
if oc explain multinetworkpolicy >/dev/null 2>&1; then
    log_success "MultiNetworkPolicy CRD is properly installed and accessible"
    
    # Show CRD information
    log_info "MultiNetworkPolicy API version:"
    oc api-resources | grep multi-networkpolicies | awk '{print $3}'
else
    log_warning "MultiNetworkPolicy CRD found but not fully accessible"
fi

# Verify cluster operators are stable
log_info "Checking cluster operators status..."
if ! oc get co network -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
    log_warning "Network operator may not be fully ready"
    oc get co network -o yaml | grep -A 5 -B 5 "conditions:"
fi

# Check multus pods are running
log_info "Checking multus-networkpolicy pods..."
multus_pods=$(oc get pods -n openshift-multus --no-headers -o custom-columns=":metadata.name" 2>/dev/null | wc -l || echo "0")
if [[ $multus_pods -gt 0 ]]; then
    log_success "Found $multus_pods multus pods running"
    oc get pods -n openshift-multus
else
    log_info "No multus pods found (may be integrated into CNI)"
fi

log_success "Multi-Network Policy enablement completed successfully"
echo "Multi-Network Policy is now ready for testing"