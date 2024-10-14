#!/usr/bin/env bash

set -euxo pipefail

# Generate registry overrides file
ACR_LOGIN_SERVER="$(</var/run/vault/acr-pull-credentials/loginserver)"
REGISTRY_OVERRIDES_FILE="$SHARED_DIR"/hypershift_operator_registry_overrides
cat <<EOF >> "$REGISTRY_OVERRIDES_FILE"
quay.io/openshift-release-dev/ocp-v4.0-art-dev=$ACR_LOGIN_SERVER/openshift-release-dev/ocp-v4.0-art-dev
quay.io/openshift-release-dev/ocp-release=$ACR_LOGIN_SERVER/openshift-release-dev/ocp-release
EOF

# Get registry overrides from file
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
oc wait deployment operator -n hypershift --for='condition=PROGRESSING=True' --timeout=1m
oc rollout status deployment -n hypershift operator --timeout=5m

