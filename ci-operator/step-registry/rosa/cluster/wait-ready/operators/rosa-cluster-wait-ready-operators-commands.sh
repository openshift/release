#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}
set_proxy

check_failed=""

# Even the cluster is shown ready on ocm side, and the cluster operators are available, some of the cluster operators are
# still progressing. The ocp e2e test scenarios requires PROGRESSING=False for each cluster operator.
echo "Wait for cluster operators' progressing ready..."
start_time=$(date +"%s")
CO_STATUS_LOG="${ARTIFACT_DIR}/co_status.log"
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=60m > "${CO_STATUS_LOG}" 2>&1 || true
end_time=$(date +"%s")
cat "${CO_STATUS_LOG}"

if grep -q "timed out" "${CO_STATUS_LOG}"; then
  check_failed="Cluster operators not done progressing within 60m"
fi

if [[ -z "${check_failed}" ]]; then
  record_cluster "timers" "co_wait_time" $(( "${end_time}" - "${start_time}" ))
  echo "All cluster operators done progressing after $(( ${end_time} - ${start_time} )) seconds"

  # Verify all cluster operators are Available and not Degraded
  echo "Checking cluster operators Available=True..."
  CO_AVAIL_LOG="${ARTIFACT_DIR}/co_available.log"
  oc wait clusteroperators --all --for=condition=Available=true --timeout=10m > "${CO_AVAIL_LOG}" 2>&1 || true
  cat "${CO_AVAIL_LOG}"
  if grep -q "timed out" "${CO_AVAIL_LOG}"; then
    check_failed="Some cluster operators are not Available"
  fi
fi

if [[ -z "${check_failed}" ]]; then
  echo "Checking cluster operators Degraded=False..."
  CO_DEGRADED_LOG="${ARTIFACT_DIR}/co_degraded.log"
  oc wait clusteroperators --all --for=condition=Degraded=false --timeout=10m > "${CO_DEGRADED_LOG}" 2>&1 || true
  cat "${CO_DEGRADED_LOG}"
  if grep -q "timed out" "${CO_DEGRADED_LOG}"; then
    check_failed="Some cluster operators are Degraded"
  fi
fi

if [[ -z "${check_failed}" ]]; then
  echo "All cluster operators are Available, not Progressing, and not Degraded"
fi

if [[ -n "${check_failed}" ]]; then
  echo "ERROR: ${check_failed}"
  oc get clusteroperators
  if [[ -e "${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url" ]]; then
    echo "Meet operator issue. Sleep 3h to call debugging."
    CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
    slack_hook_url=$(cat "${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url")
    slack_message='{"text": "'"${check_failed}"' for cluster '"${CLUSTER_ID}"'. Sleep 3 hours for debugging with the job '"${JOB_NAME}/${BUILD_ID}"'. <@UD955LPJL> <@UEEQ10T4L>"}'
    curl -X POST -H 'Content-type: application/json' --data "${slack_message}" "${slack_hook_url}"
    sleep 10800
  fi
  exit 1
fi
