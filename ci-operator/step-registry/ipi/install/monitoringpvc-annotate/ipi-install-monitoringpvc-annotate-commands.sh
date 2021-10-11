#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function annotatePVCForDeletion() {
  NS=$1
  NAME=$2

  echo "annotating PVC ${NAME} in namespace ${NS} for deletion"
  oc annotate pvc -n ${NS} ${NAME} openshift.io/cluster-monitoring-drop-pvc='yes'
}

annotatePVCForDeletion openshift-monitoring prometheus-data-prometheus-k8s-0
