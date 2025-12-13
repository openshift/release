#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc -n openshift-monitoring delete configmap cluster-monitoring-config
oc -n openshift-monitoring delete pvc --all

# oc patch clusterversion/version --patch '{"spec":{"overrides":[{"kind":"Deployment","group":"apps","name":"cluster-monitoring-operator","namespace":"openshift-monitoring","unmanaged":true}]}}' --type=merge

# oc -n openshift-monitoring delete configmap cluster-monitoring-config
# oc -n openshift-monitoring scale deploy cluster-monitoring-operator --replicas=0
# oc -n openshift-monitoring scale deploy prometheus-operator --replicas=0
# oc -n openshift-monitoring delete statefulset prometheus-k8s

# wait for prometheus pods removed
# oc -n openshift-monitoring get pod | grep prometheus-k8s
# oc -n openshift-monitoring delete pvc --all

echo "$(date -u --rfc-3339=seconds) - Delete successful."
