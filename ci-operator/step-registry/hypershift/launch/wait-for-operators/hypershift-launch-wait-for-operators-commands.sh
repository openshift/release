#!/bin/bash
set -euo pipefail

echo "$(date) Waiting for all operators to become available"

oc wait clusteroperators --all --for condition=Available --timeout 24h

echo "$(date) All operators are available"
