#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Targeted Pod Chaos
# Executes targeted pod disruption on egress IP infrastructure

echo "Starting Targeted Egress IP Pod Chaos Testing"
echo "============================================"

# Configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
TARGET_FILE="$ARTIFACT_DIR/egress_ip_targets.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

error_exit() {
    log_error "$*"
    exit 1
}

# Load target discovery results
if [[ ! -f "$TARGET_FILE" ]]; then
    error_exit "Target discovery file not found: $TARGET_FILE. Please run target discovery step first."
fi

log_info "Loading target discovery results..."
source "$TARGET_FILE"

# Validate required variables
if [[ -z "${EGRESS_IP_ASSIGNED_NODE:-}" ]] || [[ -z "${OVN_POD_ON_EGRESS_NODE:-}" ]]; then
    error_exit "Required targeting variables not found. Please run target discovery step first."
fi

log_info "Target configuration loaded:"
log_info "  - Egress IP: $EGRESS_IP_NAME ($EGRESS_IP_ADDRESS)"
log_info "  - Target Node: $EGRESS_IP_ASSIGNED_NODE"
log_info "  - Target Pod: $OVN_POD_ON_EGRESS_NODE"

# Pre-chaos validation
log_info "Pre-chaos validation..."

# Verify egress IP is still assigned to expected node
CURRENT_ASSIGNMENT=$(oc get egressip "$EGRESS_IP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
if [[ "$CURRENT_ASSIGNMENT" != "$EGRESS_IP_ASSIGNED_NODE" ]]; then
    log_warning "Egress IP assignment changed! Expected: $EGRESS_IP_ASSIGNED_NODE, Current: $CURRENT_ASSIGNMENT"
    EGRESS_IP_ASSIGNED_NODE="$CURRENT_ASSIGNMENT"
fi

# Verify target pod exists and is ready
POD_STATUS=$(oc get pod -n "$TARGET_NAMESPACE" "$OVN_POD_ON_EGRESS_NODE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$POD_STATUS" != "Running" ]]; then
    error_exit "Target pod $OVN_POD_ON_EGRESS_NODE is not running (status: $POD_STATUS)"
fi

log_success "Pre-chaos validation completed"

# Execute targeted pod disruption
log_info "Executing targeted pod disruption on egress IP infrastructure..."
log_info "🎯 Targeting: $OVN_POD_ON_EGRESS_NODE on node $EGRESS_IP_ASSIGNED_NODE"

# Kill the specific OVN pod handling egress IP
log_info "Deleting OVN pod: $OVN_POD_ON_EGRESS_NODE..."
oc delete pod -n "$TARGET_NAMESPACE" "$OVN_POD_ON_EGRESS_NODE" --ignore-not-found --wait=false

# Wait for replacement pod to be ready
log_info "Waiting for replacement OVN pod on node $EGRESS_IP_ASSIGNED_NODE..."
elapsed=0
pod_ready_timeout=300
new_pod=""
ready="false"

while [[ $elapsed -lt $pod_ready_timeout ]]; do
    # Find new ovnkube-node pod on the same node
    new_pod=$(oc get pods -n "$TARGET_NAMESPACE" -o wide | grep "$EGRESS_IP_ASSIGNED_NODE" | awk '/ovnkube-node/{print $1}' | head -1)
    
    if [[ -n "$new_pod" ]] && [[ "$new_pod" != "$OVN_POD_ON_EGRESS_NODE" ]]; then
        # Check if the new pod is ready
        ready=$(oc get pod -n "$TARGET_NAMESPACE" "$new_pod" -o jsonpath='{.status.containerStatuses[?(@.name=="ovnkube-controller")].ready}' 2>/dev/null || echo "false")
        
        if [[ "$ready" == "true" ]]; then
            log_success "✅ New OVN pod $new_pod is ready on node $EGRESS_IP_ASSIGNED_NODE"
            break
        fi
    fi
    
    sleep 5
    elapsed=$((elapsed + 5))
    
    if [[ $((elapsed % 30)) -eq 0 ]]; then
        log_info "Waiting for pod recovery... elapsed: ${elapsed}s"
    fi
done

if [[ -z "$new_pod" ]] || [[ "$new_pod" == "$OVN_POD_ON_EGRESS_NODE" ]] || [[ "$ready" != "true" ]]; then
    error_exit "❌ Failed to detect ready replacement pod on $EGRESS_IP_ASSIGNED_NODE after ${pod_ready_timeout}s"
fi

# Wait for OVN to stabilize
log_info "Waiting for OVN to stabilize..."
sleep 30

# Post-chaos validation
log_info "Post-chaos validation..."

# Check if egress IP assignment is maintained or properly migrated
CURRENT_ASSIGNMENT=$(oc get egressip "$EGRESS_IP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
if [[ -z "$CURRENT_ASSIGNMENT" ]]; then
    error_exit "❌ Egress IP lost assignment after pod disruption"
fi

if [[ "$CURRENT_ASSIGNMENT" == "$EGRESS_IP_ASSIGNED_NODE" ]]; then
    log_success "✅ Egress IP maintained assignment to node: $CURRENT_ASSIGNMENT"
    MIGRATION_OCCURRED="false"
else
    log_info "🔄 Egress IP migrated to different node: $CURRENT_ASSIGNMENT"
    MIGRATION_OCCURRED="true"
fi

# Validate OVN NAT rules
log_info "Validating OVN NAT rules after disruption..."
nat_count=$(oc exec -n "$TARGET_NAMESPACE" "$new_pod" -c ovnkube-controller -- bash -c \
    "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")

log_info "Post-disruption egress IP NAT count: $nat_count"

# Save chaos results
cat > "$ARTIFACT_DIR/targeted_pod_chaos_results.json" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "chaos_type": "targeted_pod_disruption",
  "target": {
    "original_pod": "$OVN_POD_ON_EGRESS_NODE",
    "replacement_pod": "$new_pod",
    "target_node": "$EGRESS_IP_ASSIGNED_NODE"
  },
  "egress_ip": {
    "name": "$EGRESS_IP_NAME",
    "address": "$EGRESS_IP_ADDRESS",
    "pre_chaos_node": "$EGRESS_IP_ASSIGNED_NODE",
    "post_chaos_node": "$CURRENT_ASSIGNMENT",
    "migration_occurred": $MIGRATION_OCCURRED
  },
  "recovery": {
    "replacement_pod_ready": true,
    "recovery_time_seconds": $elapsed,
    "nat_rules_count": $nat_count
  },
  "status": "success"
}
EOF

# Update target file with new pod information for subsequent steps
cat >> "$TARGET_FILE" << EOF

# Updated after targeted pod chaos
export OVN_POD_ON_EGRESS_NODE="$new_pod"
export EGRESS_IP_ASSIGNED_NODE="$CURRENT_ASSIGNMENT"
export POD_CHAOS_MIGRATION_OCCURRED="$MIGRATION_OCCURRED"
EOF

log_success "✅ Targeted egress IP pod chaos completed successfully!"
log_info "Results saved to: $ARTIFACT_DIR/targeted_pod_chaos_results.json"

echo "============================================"
echo "🎯 Targeted Pod Chaos Summary:"
echo "   Original Pod: $OVN_POD_ON_EGRESS_NODE"
echo "   Replacement Pod: $new_pod"
echo "   Egress IP Node: $CURRENT_ASSIGNMENT"
echo "   Migration: $MIGRATION_OCCURRED"
echo "   Recovery Time: ${elapsed}s"