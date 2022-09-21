#!/usr/bin/env bash

# This step checks the /readyz endpoint to confirm the
# Kubernetes environment is ready for interaction. This
# step is most useful when claiming clusters that have
# been hibernating for an extended period of time.

echo "Health endpoint and cluster operators check"

export KUBECONFIG

OPERATOR_HEALTH_TIMEOUT=${OPERATOR_HEALTH_TIMEOUT:-10}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Checking readyz endpoint"

function checkreadyz() {
  for ((n = 1; n <= OPERATOR_HEALTH_TIMEOUT; n++)); do
    api=$(oc get --raw='/readyz' 2> /dev/null)
    if test "${api}" != "ok"; then
      echo "Health check endpoint readyz not ok; checking again in one minute"
      sleep 60
      continue
    else
      echo "Health check endpoint readyz ok"
      isreadyz="ok"
      return
    fi
  done

  isreadyz="nok"
}

checkreadyz

if test "${isreadyz}" != "ok"; then
  echo "Health check endpoint readyz failed after ${OPERATOR_HEALTH_TIMEOUT} minute(s); exiting"
  exit 1
fi

echo "Checking cluster operators"

function checkclusteroperatorsconditions() {
  cops=$(oc get clusteroperators -o json 2> /dev/null|jq -r '.items|map(.status.conditions[]|select((.type=="Degraded" and .status=="True") or (.type=="Available" and .status=="False") or (.type=="Progressing" and .status=="True")))|length > 0')
  if test "${cops}" == "false"; then
    iscop="ok"
  else
    iscop="nok"
  fi

  return
}

function checkclusterversioncondition() {
  cvs=$(oc get clusterversion version -o json 2> /dev/null|jq '.status.conditions|map(select(.type=="Progressing" and .status=="True"))|length > 0')
  if test "${cvs}" == "false"; then
    iscvs="ok"
  else
    iscvs="nok"
  fi

  return
}

for ((n = 1; n <= OPERATOR_HEALTH_TIMEOUT; n++)); do
  checkclusteroperatorsconditions
  if test "${iscop}" == "ok"; then
    echo "Cluster operators ready"
    checkclusterversioncondition
    if test "${iscvs}" == "ok"; then
      echo "Cluster version ready"
     exit 0
    else
      echo "Cluster version not ready; checking again in one minute"
      sleep 60
      continue
    fi
  else
      echo "Cluster operators not ready; checking again in one minute"
      sleep 60
      continue
  fi
done

echo "Cluster operators not ready after ${OPERATOR_HEALTH_TIMEOUT} minute(s); exiting"
exit 1