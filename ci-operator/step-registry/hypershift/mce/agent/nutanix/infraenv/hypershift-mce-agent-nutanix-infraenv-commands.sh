#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster-name")
AGENT_NAMESPACE="${AGENT_NAMESPACE:-local-cluster-${CLUSTER_NAME}}"
INFRAENV_NAME="${CLUSTER_NAME}-nutanix"
PULL_SECRET_NAME="${INFRAENV_NAME}-pull-secret"
RUN_LABEL_KEY=ci.openshift.io/hcp-agent-nutanix-run

printf '%s\n' "${INFRAENV_NAME}" > "${SHARED_DIR}/nutanix_infraenv_name"
printf '%s\n' "${AGENT_NAMESPACE}" > "${SHARED_DIR}/nutanix_agent_namespace"
printf '%s\n' "${PULL_SECRET_NAME}" > "${SHARED_DIR}/nutanix_pull_secret_name"

source "${SHARED_DIR}/packet-conf.sh"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -z "${IP:-}" || -z "${PROXYPORT:-}" ]]; then
  echo "The baremetal Squid proxy endpoint is not available in the shared job configuration."
  exit 1
fi

PROXY_URL="http://${IP}:${PROXYPORT}"

oc get namespace "${AGENT_NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${AGENT_NAMESPACE}"
if ! oc get secret "${PULL_SECRET_NAME}" -n "${AGENT_NAMESPACE}" >/dev/null 2>&1; then
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  chmod 600 /tmp/.dockerconfigjson
  oc create secret generic "${PULL_SECRET_NAME}" -n "${AGENT_NAMESPACE}" \
    --from-file=.dockerconfigjson=/tmp/.dockerconfigjson --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o json | jq --arg key "${RUN_LABEL_KEY}" --arg run "${CLUSTER_NAME}" \
      '.metadata.labels = ((.metadata.labels // {}) + {($key): $run})' | oc apply -f -
  touch "${SHARED_DIR}/nutanix_pull_secret_created"
  rm -f /tmp/.dockerconfigjson
fi

ssh_key_file="${SHARED_DIR}/id_rsa.pub"
if [[ ! -s "${ssh_key_file}" && -s "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${ssh_key_file}"
fi
if [[ ! -s "${ssh_key_file}" ]]; then
  echo "No SSH public key is available for the InfraEnv."
  exit 1
fi

hostedcluster_json=$(oc get hostedcluster "${CLUSTER_NAME}" -n local-cluster -o json)
no_proxy=$(jq -r '["localhost", "127.0.0.1", "::1", ".svc", ".cluster.local", (.spec.networking.clusterNetwork[]?.cidr), (.spec.networking.serviceNetwork[]?.cidr), (.spec.networking.machineNetwork[]?.cidr)] | map(select(. != null and . != "")) | unique | join(",")' <<<"${hostedcluster_json}")
hostedcluster_proxy=$(jq -n --arg http "${PROXY_URL}" --arg https "${PROXY_URL}" --arg no_proxy "${no_proxy}" \
  '{spec:{configuration:{proxy:{httpProxy:$http,httpsProxy:$https,noProxy:$no_proxy}}}}')
oc patch hostedcluster "${CLUSTER_NAME}" -n local-cluster --type=merge -p "${hostedcluster_proxy}"

nodepool_selector=$(jq -n --arg key "${RUN_LABEL_KEY}" --arg value "${CLUSTER_NAME}" \
  '{spec:{replicas:0,platform:{agent:{agentLabelSelector:{matchLabels:{($key):$value}}}}}}')
oc patch nodepool "${CLUSTER_NAME}" -n local-cluster --type=merge -p "${nodepool_selector}"

infraenv=$(jq -n --arg name "${INFRAENV_NAME}" --arg namespace "${AGENT_NAMESPACE}" \
  --arg run "${CLUSTER_NAME}" --arg ssh_key "$(<"${ssh_key_file}")" \
  --arg pull_secret "${PULL_SECRET_NAME}" \
  --arg proxy "${PROXY_URL}" --arg no_proxy "${no_proxy}" \
  '{apiVersion:"agent-install.openshift.io/v1beta1",kind:"InfraEnv",metadata:{name:$name,namespace:$namespace,labels:{"ci.openshift.io/hcp-agent-nutanix-run":$run}},spec:{cpuArchitecture:"x86_64",pullSecretRef:{name:$pull_secret},sshAuthorizedKey:$ssh_key,agentLabels:{"ci.openshift.io/hcp-agent-nutanix-run":$run},proxy:{httpProxy:$proxy,httpsProxy:$proxy,noProxy:$no_proxy}}}')
printf '%s\n' "${infraenv}" | oc apply -f -
oc wait --namespace "${AGENT_NAMESPACE}" --for=condition=ImageCreated "infraenv/${INFRAENV_NAME}" --timeout=30m

iso_url=$(oc get infraenv "${INFRAENV_NAME}" -n "${AGENT_NAMESPACE}" -o jsonpath='{.status.isoDownloadURL}')
if [[ -z "${iso_url}" ]]; then
  echo "InfraEnv ${INFRAENV_NAME} has no ISO download URL."
  exit 1
fi
curl --fail --location --silent --show-error "${iso_url}" -o "${SHARED_DIR}/hcp-agent-nutanix.iso"
printf '%s\n' "${PROXY_URL}" > "${SHARED_DIR}/nutanix_proxy_url"
printf '%s\n' "${no_proxy}" > "${SHARED_DIR}/nutanix_no_proxy"
chmod 600 "${SHARED_DIR}/hcp-agent-nutanix.iso"
