#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

platform_type=$(oc get infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')
CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR:=""}
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json

CLUSTER_NAME=${CLUSTER_NAME:=""}
CLUSTER_NAME=$(oc get machineset -n openshift-machine-api -o=go-template='{{(index (index .items 0).metadata.labels "machine.openshift.io/cluster-api-cluster" )}}')

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure azure
az login --service-principal -u "`cat $AZURE_AUTH_LOCATION | jq -r '.clientId'`" -p "`cat $AZURE_AUTH_LOCATION | jq -r '.clientSecret'`" --tenant "`cat $AZURE_AUTH_LOCATION | jq -r '.tenantId'`"
az account set --subscription "`cat $AZURE_AUTH_LOCATION | jq -r '.subscriptionId'`"

NETWORK_NAME=$(az network nsg list -g  $CLUSTER_NAME-rg --query "[].name" -o tsv | grep "nsg")

echo "Add Firewall Rules for $platform_type"
echo "Updating security group rules for data-path test on cluster $CLUSTER_NAME"
# Typically `net.ipv4.ip_local_port_range` is set to `32768 60999` in which uperf will pick a few random ports to send flags over.
# Currently there is no method outside of sysctls to control those ports
az network nsg rule create -g $CLUSTER_NAME-rg --name scale-ci-hostnet --nsg-name $NETWORK_NAME --priority 106 --access Allow --description "scale-ci allow tcp,udp hostnetwork tests" --protocol "*" --destination-port-ranges "10000-61000"
az network nsg rule list -g $CLUSTER_NAME-rg  --nsg-name $NETWORK_NAME  | grep scale
