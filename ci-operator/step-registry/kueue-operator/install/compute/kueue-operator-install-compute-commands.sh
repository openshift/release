#!/bin/bash

set -xeuo pipefail

echo "[$(date -u --rfc-3339=seconds)] Resolving latest must-gather image..."
MUST_GATHER_REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-must-gather"
MUST_GATHER_IMAGE=$(skopeo list-tags docker://$MUST_GATHER_REPO | jq -r '.Tags[]' | grep -E '^[a-f0-9]{40}$' | while read -r tag; do
    created=$(skopeo inspect docker://$MUST_GATHER_REPO:$tag 2>/dev/null | jq -r '.Created')
    if [ "$created" != "null" ] && [ -n "$created" ]; then echo "$created $tag"; fi
done | sort | tail -n1 | awk -v repo="$MUST_GATHER_REPO" '{print repo ":" $2}')

if [[ -z "$MUST_GATHER_IMAGE" ]]; then
    echo "ERROR: Failed to resolve MUST_GATHER_IMAGE from $MUST_GATHER_REPO"
    exit 1
fi

echo "Resolved MUST_GATHER_IMAGE: ${MUST_GATHER_IMAGE}"
echo "export MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE}" >> "${SHARED_DIR}/env"
