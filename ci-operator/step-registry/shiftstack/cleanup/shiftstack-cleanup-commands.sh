#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
export CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-${CLUSTER_TYPE:-}}"
SLACK_HOOK="$(</var/run/slack-hooks/shiftstack-bot)"

EXCLUDE_ARG=""
if [ -n "${IMAGES_TTL:-}" ]; then
    EXCLUDE_ARG="--exclude=images"
    prune --resource-ttl="$IMAGES_TTL" --slack-hook="$SLACK_HOOK" --no-dry-run --include="images" > "/tmp/images-result.json"
fi

prune --resource-ttl="$RESOURCE_TTL" --slack-hook="$SLACK_HOOK" --no-dry-run "$EXCLUDE_ARG" > "/tmp/all-result.json"

if [ -n "${IMAGES_TTL:-}" ]; then
    jq -s '.[0] + .[1]' "/tmp/images-result.json" "/tmp/all-result.json" > "/tmp/result.json"
else
    cp "/tmp/all-result.json" "/tmp/result.json"
fi
