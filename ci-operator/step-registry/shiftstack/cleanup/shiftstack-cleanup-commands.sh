#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

prune --resource-ttl="$RESOURCE_TTL" --no-dry-run > "${ARTIFACT_DIR}/result.json"
