#!/bin/bash

### prerequisites
### 1. (latest version of) /usr/bin/oc, otherwise download https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
### 2. jq is installed

set -o errexit
set -o nounset
set -o pipefail

WORKDIR="$(mktemp -d)"
readonly WORKDIR

CLUSTER_NAME="build01"
readonly CLUSTER_NAME

kubectl config use-context $CLUSTER_NAME

generate_kubeconfig() {
  local sa
  sa=$1
  local config
  config="${WORKDIR}/sa.${sa}.${CLUSTER_NAME}.config"
  oc --kubeconfig "${KUBECONFIG_BUILD01}" sa create-kubeconfig -n ci "${sa}" > "${config}"
  # oc config rename-context is not enough, as we then end up
  # with multiple users with the same name when they get merged
  sed -i "s/${sa}/${CLUSTER_NAME}/g" $config
}

declare -a SAArray=( "config-updater" "deck" "plank" "sinker" "hook" "ca-cert-issuer" "crier" )

# Iterate the string array using for loop
for name in ${SAArray[@]}; do
   generate_kubeconfig ${name}
done

generate_reg_auth_value() {
  local cluster
  cluster=$1
  local registry
  registry=$3
  oc -n ci get secret $( oc get secret -n ci -o "jsonpath={.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name==\"build01\")].metadata.name}" ) -o "jsonpath={.items[?(@.type==\"kubernetes.io/dockercfg\")].data.\.dockercfg}" | base64 --decode | jq --arg reg "${registry}" -r '.[$reg].auth' | tr -d '\n' > "${WORKDIR}/build01_${cluster}_reg_auth_value.txt"
}

generate_reg_auth_value build01 "image-registry.openshift-image-registry.svc:5000"

echo "files are saved ${WORKDIR}"
