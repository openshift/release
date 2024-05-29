#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

# get cluster namesapce
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
if [[ -z "${CLUSTER_NAME}" ]] ; then
  echo "Error: cluster name not found"
  exit 1
fi

read -r namespace _ _  <<< "$(oc get cluster -A | grep ${CLUSTER_NAME})"
if [[ -z "${namespace}" ]]; then
  echo "Error: capi cluster name not found, ${CLUSTER_NAME}"
  exit 1
fi

secret_name="${CLUSTER_NAME}-kubeconfig"
if [[ "${ENABLE_EXTERNAL_OIDC}" == "true" ]]; then
  secret_name="${CLUSTER_NAME}-bootstrap-kubeconfig"
fi

max_retries=10
retry_delay=30
retries=0
secret=""
while (( retries < max_retries )); do
  secret=$(oc get secret -n ${namespace} ${secret_name} --ignore-not-found -ojsonpath='{.data.value}')
  if [[ ! -z "$secret" ]]; then
    echo "find the secret ${secret_name} in ${namespace}"
    break
  fi

  retries=$(( retries + 1 ))
  if (( retries < max_retries )); then
    echo "Retrying in $retry_delay seconds..."
    sleep $retry_delay
  else
    oc get secret -n ${namespace}
    echo "capi kubeconfig not found, exit"
    exit 1
  fi
done

if [[ !  -f "${SHARED_DIR}/mgmt_kubeconfig" ]] ; then
  mv $KUBECONFIG "${SHARED_DIR}/mgmt_kubeconfig"
fi

echo "${secret}" | base64 -d > "${SHARED_DIR}/kubeconfig"
echo "hosted cluster kubeconfig is switched"
oc whoami


