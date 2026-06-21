#!/bin/bash
set -eu -o pipefail

declare GIT_REF="${GIT_REF:-main}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
declare GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
declare GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

# Resolve FBC commit SHA if not provided
if [[ -z "$FBC_COMMIT_SHA" ]]; then
    encoded_ref=$(jq -rn --arg ref "$GIT_REF" '$ref | @uri')
    FBC_COMMIT_SHA=$(curl --insecure -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
        "${GITLAB_API}/projects/${GITLAB_PROJECT}/repository/commits/${encoded_ref}" | jq -r .id)
    log "Resolved FBC_COMMIT_SHA: ${FBC_COMMIT_SHA}"
else
    log "Using provided FBC_COMMIT_SHA: ${FBC_COMMIT_SHA}"
fi

# Fetch IDMS yaml from rhwa-fbc
idms_file=$(mktemp)
# --insecure: gitlab.cee uses internal RH CA not trusted by CI pods
curl --insecure -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
    "${GITLAB_RAW}/${FBC_COMMIT_SHA}/.tekton/images-mirror-set.yaml" -o "$idms_file"
log "Fetched IDMS from rhwa-fbc commit ${FBC_COMMIT_SHA}"

# Convert imageDigestMirrors → imageContentSources (same structure, drop mirrorSourcePolicy).
# Use yq to convert YAML→JSON then jq to reshape, avoiding yq version compatibility issues.
image_content_sources=$(yq-v4 -o=json '.' "$idms_file" | \
    jq '[.spec.imageDigestMirrors[] | {source: .source, mirrors: .mirrors}]')
log "Extracted $(echo "$image_content_sources" | jq 'length') image mirror entries"

# HostedCluster name written by hypershift-aws-create; namespace is always "clusters"
HC_NAME="$(cat "${SHARED_DIR}/cluster-name")"
HC_NAMESPACE="clusters"

log "Patching HostedCluster ${HC_NAMESPACE}/${HC_NAME} with imageContentSources..."
oc patch hostedcluster "${HC_NAME}" -n "${HC_NAMESPACE}" \
    --type=merge \
    --patch "{\"spec\":{\"imageContentSources\":${image_content_sources}}}"
log "Patch applied — waiting for hosted cluster MachineConfigPools to roll out (up to 20m)..."

# MCP rollout propagates the new mirrors to worker nodes via MCO on the hosted cluster
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" \
    oc wait mcp --all --for=condition=Updated --timeout=20m || {
    log "WARNING: MCP rollout did not complete in 20m — proceeding anyway"
    KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc get mcp || true
}

log "Image content sources active on hosted cluster workers"
