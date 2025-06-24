#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

namespace="redhat-ods-applications"

if [ -n "${ODH_MODEL_CONTROLLER_IMAGE}" ]; then
  echo "Updating odh-model-controller deployment image to ${ODH_MODEL_CONTROLLER_IMAGE}"

  echo "Scaling RHOAI operator to 0"
  oc scale --replicas=0 deployment/rhods-operator -n redhat-ods-operator

  echo "Updating odh-model-controller deployment image to ${ODH_MODEL_CONTROLLER_IMAGE}"
  oc set image  -n ${namespace}  deployment/odh-model-controller  manager="${ODH_MODEL_CONTROLLER_IMAGE}"

  echo "Wait For Deployment Replica To Be Ready"

  # Verify all pods are running
  oc_wait_for_pods() {
      local ns="${1}"
      local pods

      for _ in {1..120}; do
          echo "Waiting for pods in '${ns}' in state Running or Completed"
          pods=$(oc get pod -n "${ns}" | grep -v "Running\|Completed" | tail -n +2)
          echo "${pods}"
          if [[ -z "${pods}" ]]; then
              echo "All pods in '${ns}' are in state Running or Completed"
              break
          fi
          sleep 20
      done
      if [[ -n "${pods}" ]]; then
          echo "ERROR: Some pods in '${ns}' are not in state Running or Completed"
          echo "${pods}"
          exit 1
      fi
  }

  oc_wait_for_pods ${namespace}

  sleep 300

  echo "odh-model-controller is patched successfully"

fi

# adding sleep for debug 2h
echo "sleeping for 2h now for debug"
sleep 2h