#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
export CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-${CLUSTER_TYPE:-}}"
SLACK_HOOK="$(</var/run/slack-hooks/shiftstack-bot)"

prune --resource-ttl="$RESOURCE_TTL" --slack-hook="$SLACK_HOOK" --no-dry-run > "${ARTIFACT_DIR}/result.json"
