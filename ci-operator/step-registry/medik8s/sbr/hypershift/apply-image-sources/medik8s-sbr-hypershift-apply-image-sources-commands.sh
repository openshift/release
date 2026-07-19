#!/bin/bash
set -eu -o pipefail

declare GIT_REF="${GIT_REF:-main}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
declare GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
declare GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

declare -a _tmp_files=()
cleanup() { rm -f "${_tmp_files[@]}"; }
trap cleanup EXIT

# gitlab.cee regularly returns 503s lasting 30+ seconds; exponential backoff
# (2+4+8+16+32 = 62s window) is more reliable than curl's built-in --retry
# which doesn't retry on HTTP 5xx.  Mirrors medik8s-lib.sh gitlab_fetch().
gitlab_fetch() {
    local url="$1" output="$2" max_attempts="${3:-6}"
    local attempt delay
    for attempt in $(seq 1 "$max_attempts"); do
        if curl --insecure -sSf --connect-timeout 10 --max-time 60 \
            "$url" -o "$output" 2>/dev/null; then
            return 0
        fi
        delay=$(( 2 ** attempt ))
        log "WARNING: GitLab fetch attempt ${attempt}/${max_attempts} failed (retrying in ${delay}s)..."
        sleep "$delay"
    done
    log "ERROR: Failed to fetch ${url} after ${max_attempts} attempts"
    return 1
}

# Resolve FBC commit SHA if not provided
if [[ -z "$FBC_COMMIT_SHA" ]]; then
    encoded_ref=$(jq -rn --arg ref "$GIT_REF" '$ref | @uri')
    commit_file=$(mktemp); _tmp_files+=("$commit_file")
    gitlab_fetch "${GITLAB_API}/projects/${GITLAB_PROJECT}/repository/commits/${encoded_ref}" "$commit_file"
    FBC_COMMIT_SHA=$(jq -r .id "$commit_file")
    if [[ -z "$FBC_COMMIT_SHA" || "$FBC_COMMIT_SHA" == "null" ]]; then
        echo "ERROR: failed to resolve FBC commit SHA for ref '${GIT_REF}' (got: '${FBC_COMMIT_SHA}')"
        exit 1
    fi
    log "Resolved FBC_COMMIT_SHA: ${FBC_COMMIT_SHA}"
else
    log "Using provided FBC_COMMIT_SHA: ${FBC_COMMIT_SHA}"
fi

# Fetch IDMS yaml from rhwa-fbc
idms_file=$(mktemp); _tmp_files+=("$idms_file")
gitlab_fetch "${GITLAB_RAW}/${FBC_COMMIT_SHA}/.tekton/images-mirror-set.yaml" "$idms_file"
log "Fetched IDMS from rhwa-fbc commit ${FBC_COMMIT_SHA}"

# Convert imageDigestMirrors → imageContentSources (same structure, drop mirrorSourcePolicy).
# Use yq to convert YAML→JSON then jq to reshape, avoiding yq version compatibility issues.
image_content_sources=$(yq-v4 -o=json '.' "$idms_file" | \
    jq '[(.spec.imageDigestMirrors // [])[] | {source: .source, mirrors: .mirrors}]')
entry_count=$(echo "$image_content_sources" | jq 'length')
if [[ "$entry_count" -eq 0 ]]; then
    log "ERROR: no imageDigestMirrors entries found in IDMS file — upstream YAML may have changed"
    exit 1
fi
log "Extracted ${entry_count} image mirror entries"

# HostedCluster name written by hypershift-aws-create; namespace is always "clusters"
HC_NAME="$(cat "${SHARED_DIR}/cluster-name")"
HC_NAMESPACE="clusters"

log "Patching HostedCluster ${HC_NAMESPACE}/${HC_NAME} with imageContentSources..."
patch_file=$(mktemp); _tmp_files+=("$patch_file")
jq -n --argjson ics "$image_content_sources" \
    '{"spec":{"imageContentSources": $ics}}' > "$patch_file"
oc patch hostedcluster "${HC_NAME}" -n "${HC_NAMESPACE}" \
    --type=merge \
    --patch-file "$patch_file"
log "Patch applied — waiting for NodePool to acknowledge the config change (up to 2m)..."

# After patching HostedCluster.spec.imageContentSources, the NodePool controller takes a
# few seconds to react. AllNodesHealthy is already True at patch time, so an immediate
# wait would return instantly — before rotation starts. Wait up to 2m for the NodePool to
# report UpdatingConfig=True, confirming it has picked up the change and started rotating.
# If UpdatingConfig never fires (e.g. nodes already have the config), proceed anyway.
LABEL="hypershift.openshift.io/auto-created-for-infra=${HC_NAME}"
elapsed=0
while [[ $elapsed -lt 120 ]]; do
    updating=$(oc get nodepool -n "${HC_NAMESPACE}" -l "${LABEL}" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="UpdatingConfig")].status}' 2>/dev/null || true)
    if [[ "${updating}" == *"True"* ]]; then
        log "NodePool UpdatingConfig=True — rotation has started"
        break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
done
if [[ $elapsed -ge 120 ]]; then
    log "NodePool UpdatingConfig never fired — nodes may already have the correct config, proceeding"
fi

log "Waiting for NodePool(s) AllNodesHealthy after rotation (up to 20m)..."
oc wait nodepool -n "${HC_NAMESPACE}" \
    -l "${LABEL}" \
    --for=condition=AllNodesHealthy --timeout=20m || {
    log "ERROR: NodePool(s) did not reach AllNodesHealthy in 20m"
    oc get nodepool -n "${HC_NAMESPACE}" -l "${LABEL}" -o wide || true
    exit 1
}

log "Image content sources active on hosted cluster workers"
