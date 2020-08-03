#!/bin/bash

### prerequisites
### 1. (latest version of) /usr/bin/oc, otherwise download https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
### 2. jq is installed

set -o errexit
set -o nounset
set -o pipefail

WORKDIR="$(mktemp -d)"
readonly WORKDIR

declare -a App_CI_SAArray=("config-updater" "deck" "plank" "sinker" "hook" "crier" "release-bot" "prow-controller-manager" "pj-rehearse")
declare -a Build01_SAArray=("config-updater" "deck" "plank" "sinker" "hook" "crier" "dptp-controller-manager" "prow-controller-manager" "ci-operator")
declare -a Build02_SAArray=("${Build01_SAArray[@]}")

declare -a Context_Array=("app.ci" "build01" "build02")

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

declare -a SAArray=()

for ctx in ${Context_Array[@]}; do
  CONTEXT=${ctx}
  if [[ ${CONTEXT} == "app.ci" ]]; then SAArray=("${App_CI_SAArray[@]}"); fi
  if [[ ${CONTEXT} == "build01" ]]; then SAArray=("${Build01_SAArray[@]}"); fi
  if [[ ${CONTEXT} == "build02" ]]; then SAArray=("${Build02_SAArray[@]}"); fi
  for name in ${SAArray[@]}; do
    if ! generate_kubeconfig "${name}"; then
      echo "failed"
      exit 1
    fi
  done
done

generate_reg_auth_value() {
  local cluster
  cluster=$1
  local registry
  registry=$2
  oc --context "${CONTEXT}" -n ci get secret $( oc --context ${CONTEXT} get secret -n ci -o "jsonpath={.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name==\"build01\")].metadata.name}" ) -o "jsonpath={.items[?(@.type==\"kubernetes.io/dockercfg\")].data.\.dockercfg}" | base64 --decode | jq --arg reg "${registry}" -r '.[$reg].auth' | tr -d '\n' > "${WORKDIR}/build01_${cluster}_reg_auth_value.txt"
}

for ctx in ${Context_Array[@]}; do
  CONTEXT=${ctx}
  generate_reg_auth_value "${CONTEXT}" "image-registry.openshift-image-registry.svc:5000"
done

echo "files are saved ${WORKDIR}"
