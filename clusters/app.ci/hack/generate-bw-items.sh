#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

declare -a SAArray=( "config-updater" "deck" "plank" "sinker" "hook" "crier" )
readonly CLUSTER_NAME="app.ci"

WORKDIR="$(mktemp -d /tmp/kubeconfigs-app-ci-$(date --iso-8601).XXXX)"
readonly WORKDIR

kubectl config use-context $CLUSTER_NAME

generate_kubeconfig() {
  local sa
  sa=$1
  local config
  config="${WORKDIR}/sa.${sa}.${CLUSTER_NAME}.config"
  oc sa create-kubeconfig -n ci "${sa}" > "${config}"
  KUBECONFIG=$config oc config rename-context "${sa}" $CLUSTER_NAME
}

for name in ${SAArray[@]}; do
  generate_kubeconfig $name
done

echo "Configs saved to $WORKDIR"
