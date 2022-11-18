#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy windup
# oc apply -f - <<EOF
# apiVersion: windup.jboss.org/v1
# kind: Windup
# metadata:
#     name: mta
#     namespace: mta
# spec:
#     mta_Volume_Cpacity: "5Gi"
#     volumeCapacity: "5Gi"
# EOF


echo "MTA operator installed and Windup deployed."

echo "DEBUGGING..."

console_route=$(oc get route -n openshift-console console -o yaml)
echo "CONSOLE ROUTE"
echo $console_route

pwd=$(pwd)
echo "PWD"
echo $pwd

env=$(env | sort)
echo "ENVIRONMENT VARIABLES"
echo $env

hostname=$(hostname)
echo "HOSTNAME"
echo $hostname

user=$(whoami)
echo "USER"
echo $user