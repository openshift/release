#!/bin/bash

### prerequisites
### 1. (latest version of) /usr/bin/oc, otherwise download https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
### 2. oc login api-build01-ci-devcluster-openshift-com:6443 and save the config file to ${HOME}/.kube/build01.config or change the path below
### 3. jq is installed

set -o errexit
set -o nounset
set -o pipefail

WORKDIR="$(mktemp -d)"
readonly WORKDIR

KUBECONFIG_BUILD01="${HOME}/.kube/build01.config"
readonly KUBECONFIG_BUILD01

if [[ ! -f "${KUBECONFIG_BUILD01}" ]]; then
    echo "File ${KUBECONFIG_BUILD01} not found!"
    exit 1
fi

CLUSTER_NAME="build01"
readonly CLUSTER_NAME
API_SERVER="api.build01.ci.devcluster.openshift.com:6443"
readonly API_SERVER

generate_kubeconfig() {
  local sa
  sa=$1
  local config
  config="${WORKDIR}/sa.${sa}.${CLUSTER_NAME}.config"
  local token
  token=$(oc --kubeconfig "${KUBECONFIG_BUILD01}" sa get-token -n ci "${sa}")
  oc login ${API_SERVER} --token ${token} --kubeconfig "${config}"
  oc --kubeconfig "${config}" project ci
  #strange --kubeconfig does not work here
  #https://coreos.slack.com/archives/CEKNRGF25/p1578065888081000
  oc --config "${config}" config rename-context "ci/api-build01-ci-devcluster-openshift-com:6443/system:serviceaccount:ci:${sa}" ci/api-build01-ci-devcluster-openshift-com:6443
  #depending on how many projects the SA has access to, there could be another context  generated without namespace after oc-login
  #we leave it there for simplicity
}

declare -a SAArray=( "config-updater" "deck" "plank" "sinker" "hook" "ci-operator" "ca-cert-issuer" )
 
# Iterate the string array using for loop
for name in ${SAArray[@]}; do
   generate_kubeconfig ${name}
done

generate_reg_auth_value() {
  local cluster
  cluster=$1
  local config
  config=$2
  local registry
  registry=$3
  oc --kubeconfig "${config}" -n ci get secret $( oc --kubeconfig "${KUBECONFIG_BUILD01}" get secret -n ci -o "jsonpath={.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name==\"build01\")].metadata.name}" ) -o "jsonpath={.items[?(@.type==\"kubernetes.io/dockercfg\")].data.\.dockercfg}" | base64 --decode | jq --arg reg "${registry}" -r '.[$reg].auth' > "${WORKDIR}/build01_${cluster}_reg_auth_value.txt"
}

generate_reg_auth_value build01 "${KUBECONFIG_BUILD01}" "image-registry.openshift-image-registry.svc:5000"

echo "files are saved ${WORKDIR}"
