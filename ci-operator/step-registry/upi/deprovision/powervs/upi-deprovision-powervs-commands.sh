#!/bin/bash

SECONDS=0

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

POWERVS_JENKINS_URL="$( cat /etc/credentials/JENKINS_URL )"
POWERVS_JENKINS_USER="$( cat /etc/credentials/JENKINS_USER )"
POWERVS_JENKINS_TOKEN="$( cat /etc/credentials/JENKINS_TOKEN )"

# The action that will be executed by Jenkins
export ACTION="destroy"
export POWERVS_JENKINS_URL
export POWERVS_JENKINS_USER
export POWERVS_JENKINS_TOKEN

CLUSTER_ID=$(grep "Cluster ID" < "${SHARED_DIR}"/access-details | tr -d " " | awk -F ":" '{print $2}')
export CLUSTER_ID

echo "$(date -u --rfc-3339=seconds) - Destroying a cluster on PowerVS"

/usr/local/bin/python3.9 /cluster/powervs.py

TOTAL_EXEC_TIME=$SECONDS
echo "INFO: Execution time took $(($TOTAL_EXEC_TIME / 60)) minutes and $(($TOTAL_EXEC_TIME % 60)) seconds."
