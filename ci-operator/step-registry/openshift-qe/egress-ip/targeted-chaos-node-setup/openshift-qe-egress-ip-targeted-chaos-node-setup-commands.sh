#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Targeted Node Chaos Setup
# Configures environment for targeted node disruption

echo "Setting up Targeted Node Chaos for Egress IP Testing"
echo "=================================================="

# Configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
TARGET_FILE="$ARTIFACT_DIR/egress_ip_targets.env"

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

error_exit() {
    echo -e "\033[0;31m[ERROR]\033[0m $*"
    exit 1
}

# Load target discovery results
if [[ ! -f "$TARGET_FILE" ]]; then
    error_exit "Target discovery file not found: $TARGET_FILE"
fi

log_info "Loading target configuration..."
source "$TARGET_FILE"

# Validate required variables
if [[ -z "${EGRESS_IP_ASSIGNED_NODE:-}" ]]; then
    error_exit "EGRESS_IP_ASSIGNED_NODE not found in target configuration"
fi

log_info "Configuring targeted node chaos:"
log_info "  - Target Node: $EGRESS_IP_ASSIGNED_NODE"
log_info "  - Egress IP: ${EGRESS_IP_NAME:-} (${EGRESS_IP_ADDRESS:-})"

# Set environment variables for the subsequent node chaos step
export NODE_NAME="$EGRESS_IP_ASSIGNED_NODE"
export INSTANCE_COUNT="1"
export LABEL_SELECTOR=""  # Don't use generic selector
export RUNS="${RUNS:-3}"

# Write configuration for node chaos step
cat > "$ARTIFACT_DIR/node_chaos_config.env" << EOF
export NODE_NAME="$EGRESS_IP_ASSIGNED_NODE"
export INSTANCE_COUNT="1"
export LABEL_SELECTOR=""
export RUNS="$RUNS"
export NODE_OUTAGE_TIMEOUT="${NODE_OUTAGE_TIMEOUT:-180}"
export ACTION="${ACTION:-node_reboot_scenario}"
EOF

log_info "Node chaos configuration:"
log_info "  - NODE_NAME: $EGRESS_IP_ASSIGNED_NODE"
log_info "  - INSTANCE_COUNT: 1"
log_info "  - RUNS: ${RUNS:-3}"
log_info "  - ACTION: ${ACTION:-node_reboot_scenario}"

# Verify node exists and is ready
NODE_STATUS=$(oc get node "$EGRESS_IP_ASSIGNED_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
if [[ "$NODE_STATUS" != "True" ]]; then
    error_exit "Target node $EGRESS_IP_ASSIGNED_NODE is not ready (status: $NODE_STATUS)"
fi

log_success "✅ Target node validated and chaos configuration prepared"
log_info "Next step will execute targeted node reboot on: $EGRESS_IP_ASSIGNED_NODE"

echo "=================================================="