#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

set -x

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# logger function prints standard logs
logger() {
    local level="$1"
    local message="$2"
    local timestamp

    # Generate a timestamp for the log entry
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Print the log message with the level and timestamp
    echo "[$timestamp] [$level] $message"
}

checkPodStatus() {
  i=0
  period=1
  while true; do
    PODNAME=$(oc get pod -n openshift-cluster-csi-drivers | grep "aws-efs-csi-driver-operator" | awk '{print $1}')
    STATUS=$(oc get pod -n openshift-cluster-csi-drivers --no-headers | grep "aws-efs-csi-driver-operator" | awk '{print $3}')
    if [ $STATUS == "$1" ]; then 
      logger "INFO" "Matched the expected status: $STATUS"
      break
    fi
    ((i=i+1))
    sleep $period
    if [ $i -ge 10 ]; then
      logger "ERROR" "The Pod did not reach to Running status"
      oc describe pod $PODNAME -n openshift-cluster-csi-drivers
      exit 1
    fi
  done
}

SubscriptionName=`oc get subscription -n openshift-cluster-csi-drivers | grep "aws-efs-csi-driver-operator" | awk '{print $1}'`
logger "INFO" "EFS Subscription name is $SubscriptionName"

ROLEARN=$(oc get subscription $SubscriptionName -n openshift-cluster-csi-drivers -o json | jq -r '.spec.config.env[] | select(.name=="ROLEARN") | .value')
logger "INFO" "The ROLE ARN value is $ROLEARN"

SAName=$(oc get sa -n openshift-cluster-csi-drivers | grep "aws-efs-csi-driver-operator" | awk '{print $1}')
logger "INFO" "The Service account name is $SAName" 

oc patch sa/$SAName -n openshift-cluster-csi-drivers --type='merge' -p "{\"metadata\": {\"annotations\": {\"eks.amazonaws.com/role-arn\": \"$ROLEARN\", \"eks.amazonaws.com/audience\": \"sts.amazonaws.com\"}}}"

PODNAME=$(oc get pods -n openshift-cluster-csi-drivers | grep "aws-efs-csi-driver-operator" | awk '{print $1}')
logger "INFO" $PODNAME
oc delete pod/$PODNAME -n openshift-cluster-csi-drivers 
checkPodStatus "Running"
PODNAME=$(oc get pods -n openshift-cluster-csi-drivers | grep "aws-efs-csi-driver-operator" | awk '{print $1}')
logger "INFO" $PODNAME