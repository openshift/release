#!/bin/bash

### prerequisites
### 1. (latest version of) /usr/bin/oc, otherwise download https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
### 2. jq is installed

set -o errexit
set -o nounset
set -o pipefail

WORKDIR="$(mktemp -d)"
readonly WORKDIR

CONTEXT="build02"
readonly CONTEXT

SED_COMMAND="sed"
if [[ "$(uname -s)" == "Darwin" ]]; then
  SED_COMMAND="gsed"
fi

generate_kubeconfig() {
  local sa
  sa=$1
  local config
  config="${WORKDIR}/sa.${sa}.${CONTEXT}.config"
  oc --context "${CONTEXT}" sa create-kubeconfig -n ci "${sa}" > "${config}"
  "${SED_COMMAND}" -i "s/${sa}/${CONTEXT}/g" "${config}"
  if [[ "$(oc --kubeconfig ${config} --context ${CONTEXT} whoami)" != "system:serviceaccount:ci:${sa}" ]]; then
    echo "not good kubeconfig ${config} for the expected SA ${sa}"
    return 1
  fi
}

declare -a SAArray=( "config-updater" "deck" "plank" "sinker" "hook" "crier" "ci-operator" "dptp-controller-manager" "prow-controller-manager" "ci-operator")

# Iterate the string array using for loop
for name in ${SAArray[@]}; do
  if ! generate_kubeconfig "${name}"; then
     exit 1
  fi
done

generate_reg_auth_value() {
  local cluster
  cluster=$1
  local registry
  registry=$2
  oc --context "${CONTEXT}" -n ci get secret $( oc --context ${CONTEXT} get secret -n ci -o "jsonpath={.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name==\"build01\")].metadata.name}" ) -o "jsonpath={.items[?(@.type==\"kubernetes.io/dockercfg\")].data.\.dockercfg}" | base64 --decode | jq --arg reg "${registry}" -r '.[$reg].auth' | tr -d '\n' > "${WORKDIR}/build01_${cluster}_reg_auth_value.txt"
}

#generate_reg_auth_value "${CONTEXT}" "image-registry.openshift-image-registry.svc:5000"

echo "files are saved ${WORKDIR}"
