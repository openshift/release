#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -z "${OO_PREVIOUS_BUNDLE}" ]]; then
  echo "OO_PREVIOUS_BUNDLE must be set to the previous Custom Metrics Autoscaler operator bundle image" >&2
  exit 1
fi

oc create ns keda
oc annotate namespace keda keda-olm-operator/create-default-controller=skip --overwrite
operator-sdk run bundle --timeout=5m --security-context-config restricted -n keda "${OO_PREVIOUS_BUNDLE}"
oc wait --for condition=Available -n keda deployment custom-metrics-autoscaler-operator --timeout 10m
