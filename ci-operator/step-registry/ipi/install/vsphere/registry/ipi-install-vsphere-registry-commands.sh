#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function operator_progress() {
while true; do
        progress=$(oc -o yaml get clusteroperators.config.openshift.io $1 -o go-template='{{ range .status.conditions -}}{{if eq .type "Progressing" -}}{{.status}}{{end -}}{{end -}}')
        if [[ "${progress}" == "True" ]]; then
                sleep 15
                printf "."
        else
                break
        fi
done
}


export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

operator_progress image-registry
operator_progress kube-apiserver

