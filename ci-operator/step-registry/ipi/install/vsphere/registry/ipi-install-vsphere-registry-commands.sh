#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function operator_progress() {
while true; do
        progress=$(oc -o yaml get clusteroperators.config.openshift.io $1 -o go-template='{{ range .status.conditions -}}{{if eq .type "Progressing" -}}{{.status}}{{end -}}{{end -}}'|| true)
        if [[ "${progress}" == "True" ]]; then
                sleep 15
                echo "."
        else
                break
        fi
done
}


export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

echo "Sleep 30..."
sleep 30


echo "wait for image-registry"
operator_progress image-registry || true
echo "wait for kube-apiserver"
operator_progress kube-apiserver || true

