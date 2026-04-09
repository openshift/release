#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc apply -n keda -f config/samples/keda_v1alpha1_kedacontroller.yaml
sleep 30
oc get deployment -n keda
oc wait --for condition=Available -n keda deployment keda-admission --timeout 10m
oc wait --for condition=Available -n keda deployment keda-metrics-apiserver --timeout 10m
oc wait --for condition=Available -n keda deployment keda-operator --timeout 10m
oc get deployment -n keda
