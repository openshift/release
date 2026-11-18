#!/bin/bash
set -euo pipefail

# Exercise the start-priority CLI from one ARO-HCP revision in a real Prow job.
# Everything this step runs is read-only: the checkout is a scratch clone and the
# only outputs are artifacts.

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
error() {
    log "[error] $*"
    exit 1
}

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/cli-check.XXXXXX")
trap 'rm -rf "${WORKDIR}"' EXIT

for tool in git go jq; do
    command -v "${tool}" >/dev/null 2>&1 || error "required tool '${tool}' is not installed"
done

log "fetching Azure/ARO-HCP at ${ARO_HCP_REF}"
git init --quiet "${WORKDIR}/aro-hcp"
git -C "${WORKDIR}/aro-hcp" remote add origin https://github.com/Azure/ARO-HCP.git
git -C "${WORKDIR}/aro-hcp" fetch --quiet --depth 1 origin "${ARO_HCP_REF}" ||
    error "cannot fetch ${ARO_HCP_REF}"
git -C "${WORKDIR}/aro-hcp" checkout --quiet FETCH_HEAD
REPO="${WORKDIR}/aro-hcp"
resolved=$(git -C "${REPO}" rev-parse HEAD) || error "cannot resolve the checked out revision"
log "checked out ${resolved}"

log "building aro-hcp-tests"
(
    cd "${REPO}/test" &&
        GOFLAGS=-mod=vendor go build -o "${WORKDIR}/aro-hcp-tests" ./cmd/aro-hcp-tests
) || error "cannot build aro-hcp-tests"

RUNNER="${WORKDIR}/aro-hcp-tests"
for cred in client-id client-secret tenant; do
    [[ -r "/var/run/aro-hcp-dev/${cred}" ]] || error "azure credential file not found: ${cred}"
done
export AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
AZURE_CLIENT_ID=$(cat /var/run/aro-hcp-dev/client-id)
AZURE_CLIENT_SECRET=$(cat /var/run/aro-hcp-dev/client-secret)
AZURE_TENANT_ID=$(cat /var/run/aro-hcp-dev/tenant)
export AZURE_TOKEN_CREDENTIALS=prod

log "command surface"
"${RUNNER}" priorities --help >"${ARTIFACT_DIR}/priorities-help.txt" 2>&1
"${RUNNER}" refresh-priorities --help >"${ARTIFACT_DIR}/refresh-priorities-help.txt" 2>&1
"${RUNNER}" priorities-summary --help >"${ARTIFACT_DIR}/priorities-summary-help.txt" 2>&1

log "collecting ${KUSTO_CLUSTER} telemetry"
"${RUNNER}" priorities \
    --kusto "${KUSTO_CLUSTER}" \
    --region "${KUSTO_REGION}" \
    --database "${KUSTO_DATABASE}" \
    --job-filter e2e-parallel \
    --since 720h \
    --min-samples 3 \
    --timeout 10m \
    --output json >"${ARTIFACT_DIR}/priority-scores.json" ||
    error "priorities failed"

log "listing the catalog"
"${RUNNER}" list tests --output json >"${ARTIFACT_DIR}/catalog-before.json" ||
    error "list tests failed"

log "rendering the summary from the in-memory plan"
"${RUNNER}" refresh-priorities \
    --report "${ARTIFACT_DIR}/priority-scores.json" \
    --catalog "${ARTIFACT_DIR}/catalog-before.json" \
    --repo "${REPO}" \
    --summary-html "${ARTIFACT_DIR}/priorities-summary.html" \
    --summary-note "CLI check from ARO-HCP ${resolved}" \
    >"${ARTIFACT_DIR}/priority-changes.json" ||
    error "refresh-priorities failed"

created=$(jq '.changes | length' "${ARTIFACT_DIR}/priority-changes.json") ||
    error "cannot read the change summary"
[[ -z "$(git -C "${REPO}" status --porcelain)" ]] ||
    error "the preview modified the checkout"
log "preview finished with ${created} proposed changes; the checkout is unchanged"
