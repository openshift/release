#!/bin/bash

set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "$(date) Checking SNO node status"
oc wait node --all --for=condition=Ready=true --timeout=30m
echo "$(date) SNO node is ready"

echo "$(date) Verifying cluster operators"
oc wait --all=true clusteroperator --for=condition=Available=True --timeout=30m
echo "$(date) All cluster operators are available"
