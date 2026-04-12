#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc get deployment -n keda
operator-sdk cleanup -n keda keda
oc wait --for=delete -n keda deployment custom-metrics-autoscaler-operator --timeout 10m
