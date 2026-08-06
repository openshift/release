#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

function check_imageregistry_back_ready(){
  iter=5
  period=60
  echo "INFO" "Wait image registry ready(max 5min)....."
  local result=""
  while [[ "${result}" != "TrueFalse" && $iter -gt 0 ]]; do
    sleep $period
    result=$(oc get co image-registry -o=jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}')
    (( iter -- ))
  done
  if [ "${result}" != "TrueFalse" ]; then
    echo "Warning" "Image registry is not ready, please check"
    oc get pods -n openshift-image-registry
    oc get co image-registry -o yaml
    return 1
  else
    return 0
  fi
}

if [[ "${STORAGE}" == "emptyDir" ]]; then
    oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState": "Managed","replicas":1,"storage":{"emptyDir":{}}}}' && check_imageregistry_back_ready || exit 1
fi
