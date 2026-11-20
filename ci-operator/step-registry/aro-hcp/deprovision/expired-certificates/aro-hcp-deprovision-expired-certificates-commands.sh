#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-dev"
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

# Rehearsals are presubmits and must not inherit the periodic job's deletion setting.
dry_run="${CERTIFICATE_CLEANUP_DRY_RUN}"
if [[ "${JOB_TYPE:-}" != periodic ]]; then
  dry_run=true
fi

cleanup-sweeper --workflow=certificates \
  --policy="${CERTIFICATE_CLEANUP_POLICY}" \
  --dry-run="${dry_run}" \
  --options="certificates.max-deletions=${CERTIFICATE_CLEANUP_MAX_DELETIONS}" \
  --options="certificates.max-purges=${CERTIFICATE_CLEANUP_MAX_PURGES}" \
  --parallelism="${CERTIFICATE_CLEANUP_PARALLELISM}" \
  --timeout="${CERTIFICATE_CLEANUP_TIMEOUT}"
