#!/usr/bin/env bash

set -euxo pipefail

# Registry overrides
REGISTRY_OVERRIDES_FILE="$SHARED_DIR"/hypershift_operator_registry_overrides
if [[ ! -f "$REGISTRY_OVERRIDES_FILE" ]]; then
    echo "Registry override file $REGISTRY_OVERRIDES_FILE not found, exiting" >&2
    exit 1
fi

REGISTRY_OVERRIDES=""
while read -r line || [[ -n "$line" ]]; do
    if [[ -z $line ]]; then
        continue
    fi

    if [[ -n $REGISTRY_OVERRIDES ]]; then
        REGISTRY_OVERRIDES+=","
    fi
    REGISTRY_OVERRIDES+="$line"
done < "$REGISTRY_OVERRIDES_FILE"

oc patch deployment operator -n hypershift --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "'"--registry-overrides=$REGISTRY_OVERRIDES"'"
  }
]'
oc wait deployment -n hypershift operator --for=condition=Available --timeout=5m

