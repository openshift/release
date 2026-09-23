#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

operator-sdk run bundle-upgrade --timeout=5m --security-context-config restricted -n keda "$OO_BUNDLE"
oc wait --for condition=Available -n keda deployment custom-metrics-autoscaler-operator --timeout 10m
