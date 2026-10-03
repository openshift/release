#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

CREDS_DIR=/var/run/aro-ea-sub2-cleanup
export AZURE_CLIENT_ID; AZURE_CLIENT_ID="$(<"${CREDS_DIR}/client-id")"
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET="$(<"${CREDS_DIR}/client-secret")"
export AZURE_TENANT_ID; AZURE_TENANT_ID="$(<"${CREDS_DIR}/tenant-id")"
export AZURE_TOKEN_CREDENTIALS=prod

if [[ ! "${CLEANUP_SWEEPER_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "CLEANUP_SWEEPER_COMMIT must be a full 40-character commit SHA, got '${CLEANUP_SWEEPER_COMMIT}'" >&2
  exit 1
fi

# Only scheduled periodics may delete; rehearsals and ad-hoc runs are forced to dry-run.
dry_run=true
if [[ "${JOB_TYPE:-}" == "periodic" && "${CLEANUP_DRY_RUN}" == "false" ]]; then
  dry_run=false
fi
echo "subscription=${CLEANUP_SUBSCRIPTION_ID} commit=${CLEANUP_SWEEPER_COMMIT} dry-run=${dry_run} (JOB_TYPE=${JOB_TYPE:-unset})"

src=/tmp/aro-hcp
git init -q "${src}"
git -C "${src}" remote add origin https://github.com/Azure/ARO-HCP.git
git -C "${src}" fetch -q --depth=1 --filter=blob:none origin "${CLEANUP_SWEEPER_COMMIT}"
git -C "${src}" sparse-checkout set tooling/cleanup-sweeper internal
git -C "${src}" checkout -q FETCH_HEAD
if [[ "$(git -C "${src}" rev-parse HEAD)" != "${CLEANUP_SWEEPER_COMMIT}" ]]; then
  echo "checked-out commit does not match CLEANUP_SWEEPER_COMMIT" >&2
  exit 1
fi
(cd "${src}/tooling/cleanup-sweeper" && GOWORK=off GOTOOLCHAIN=auto GOFLAGS=-mod=readonly go build -o /tmp/cleanup-sweeper .)

# First matching rule wins. Mirrors the retired ADO pruner (ARO-RP hack/clean).
cat > /tmp/rg-cleanup.policy.yaml <<'EOF'
rgOrdered:
  # Shared RGs denylisted by ARO-RP hack/clean.
  excludedResourceGroups:
  - dns
  - images
  - secrets
  - management-eastus
  - management-westeurope
  - management-australiasoutheast
  - v4-eastus
  - v4-westeurope
  - v4-australiasoutheast
  - v4-eastus-aks1
  - v4-westeurope-aks1
  - v4-australiasoutheast-aks1
  discovery:
    rules:
    - name: skip-managed-resource-groups
      action: skip
      match:
        any: true
      conditions:
        managedByAlive: true
    - name: skip-persist-true
      action: skip
      match:
        any: true
      conditions:
        tagsEq:
          persist: "true"
    - name: delete-after-48h
      action: delete
      match:
        any: true
      olderThan: "48h"
EOF

/tmp/cleanup-sweeper \
  --workflow rg-ordered \
  --subscription-id "${CLEANUP_SUBSCRIPTION_ID}" \
  --policy /tmp/rg-cleanup.policy.yaml \
  --dry-run="${dry_run}" \
  --parallelism 1 \
  --wait=false
