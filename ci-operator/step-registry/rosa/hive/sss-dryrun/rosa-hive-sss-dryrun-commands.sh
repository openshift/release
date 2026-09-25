#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Server-side dry-run validation of MCC SelectorSyncSet templates.
# Uses the backplane kubeconfig from the rosa-hive-backplane-login pre step.

log() { echo -e "\033[1m$(date '+%d-%m-%YT%H:%M:%S') $*\033[0m"; }

# Use the kubeconfig from the pre step (rosa-hive-backplane-login)
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
log "Using backplane kubeconfig from pre step: ${KUBECONFIG}"
log "Target server: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
log "Authenticated as: $(oc whoami 2>/dev/null || echo 'unknown')"

# Generate SelectorSyncSet templates
log "Generating SelectorSyncSet templates via make"
export IN_CONTAINER=true
make

# Fix apiVersion: the .tmpl uses "v1" which oc process doesn't recognize;
# it needs "template.openshift.io/v1"
TEMPLATE="hack/00-osd-managed-cluster-config-integration.yaml.tmpl"
log "Fixing apiVersion in ${TEMPLATE}"
sed -i 's|^apiVersion: v1$|apiVersion: template.openshift.io/v1|' "${TEMPLATE}"

# Process template with integration parameters (dummy values for schema validation)
PROCESSED="${ARTIFACT_DIR}/processed-sss.yaml"
log "Processing ${TEMPLATE} (ENV=int) with integration parameters"
oc process --local -f "${TEMPLATE}" \
    -p ENV=int \
    -p IMAGE_TAG=latest \
    -p REPO_NAME=managed-cluster-config \
    -p TELEMETER_SERVER_URL=https://telemeter.example.com \
    -p OCM_BASE_URL=https://api.example.com \
    -p CONSOLE_BASE_URL=https://console.example.com \
    -p SREP_LEGAL_ENTITY_ID=dummy-legal-entity-id \
    -p LOG_LINKING_ENTITY_IDS=dummy-log-linking-id \
    -p 'ALLOWED_CIDR_BLOCKS=10.0.0.0/8' \
    -p 'ROUTER_REPLICA_CLUSTER_IDS=["dummy-cluster-id"]' \
    -p 'ROUTER_REPLICA_ORG_IDS=["dummy-org-id"]' \
    -p SEGMENT_API_KEY=dummy-segment-api-key \
    -p OBSERVATORIUM_URL=https://observatorium.example.com \
    -o yaml > "${PROCESSED}"

log "Processed template saved to ${PROCESSED}"

# Server-side dry-run apply
log "Server-side dry-run apply of processed SelectorSyncSets"
oc apply --dry-run=server -f "${PROCESSED}"

log "All SelectorSyncSets passed server-side dry-run validation"
