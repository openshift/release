#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

go build -o /tmp/cleanup-sweeper ./tooling/cleanup-sweeper

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

/tmp/cleanup-sweeper ci-certificates \
  --dry-run="${dry_run}" \
  --min-age="${CERTIFICATE_CLEANUP_MIN_AGE}" \
  --max-deletions="${CERTIFICATE_CLEANUP_MAX_DELETIONS}" \
  --timeout=30m
