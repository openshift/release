#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster-name")
AGENT_NAMESPACE="${AGENT_NAMESPACE:-local-cluster-${CLUSTER_NAME}}"
INFRAENV_NAME="${CLUSTER_NAME}-nutanix"
PULL_SECRET_NAME="${INFRAENV_NAME}-pull-secret"
RUN_LABEL_KEY=ci.openshift.io/hcp-agent-nutanix-run
NETWORK_CONFIG_LABEL_KEY=ci.openshift.io/hcp-agent-nutanix-nmstate

if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ || ! "${NUTANIX_WORKERS:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "A valid HostedCluster name and positive NUTANIX_WORKERS count are required."
  exit 1
fi

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
temp_dir=$(mktemp -d)
trap 'rm -rf -- "${temp_dir}"' EXIT

oc get namespace "${AGENT_NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${AGENT_NAMESPACE}"
if ! oc get secret "${PULL_SECRET_NAME}" -n "${AGENT_NAMESPACE}" >/dev/null 2>&1; then
  oc extract secret/pull-secret -n openshift-config --to="${temp_dir}" --confirm
  chmod 600 "${temp_dir}/.dockerconfigjson"
  oc create secret generic "${PULL_SECRET_NAME}" -n "${AGENT_NAMESPACE}" \
    --from-file=.dockerconfigjson="${temp_dir}/.dockerconfigjson" --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml > "${temp_dir}/pull-secret.yaml"
  oc label --local -f "${temp_dir}/pull-secret.yaml" \
    "${RUN_LABEL_KEY}=${CLUSTER_NAME}" -o yaml > "${temp_dir}/labeled-pull-secret.yaml"
  oc apply -f "${temp_dir}/labeled-pull-secret.yaml"
  touch "${SHARED_DIR}/nutanix_pull_secret_created"
fi

ssh_key_file="${SHARED_DIR}/id_rsa.pub"
if [[ ! -s "${ssh_key_file}" && -s "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${ssh_key_file}"
fi
if [[ ! -s "${ssh_key_file}" ]]; then
  echo "No SSH public key is available for the InfraEnv."
  exit 1
fi

if [[ ! -s "${SHARED_DIR}/hostedcluster_no_proxy" ]]; then
  echo "The HostedCluster proxy configuration is not available in the shared job configuration."
  exit 1
fi
no_proxy=$(<"${SHARED_DIR}/hostedcluster_no_proxy")

dns_state_file="${SHARED_DIR}/nutanix_worker_dns_state.json"
if [[ ! -s "$dns_state_file" ]]; then
  echo "The run-scoped worker DNS resolver must be ready before creating the InfraEnv."
  exit 1
fi
if ! worker_dns_ip=$(jq -er --arg cluster "$CLUSTER_NAME" --arg lease "${NUTANIX_QUOTA_SLICE:-}" \
  'select(.cluster == $cluster and .lease == $lease) | .advertisedIP' "$dns_state_file"); then
  echo "The worker DNS state does not match this HostedCluster and Nutanix lease."
  exit 1
fi
worker_macs_file="${SHARED_DIR}/nutanix_worker_macs.json"
if [[ -e "$worker_macs_file" ]]; then
  echo "Worker MAC reservations already exist; clean up the previous setup before retrying."
  exit 1
fi
worker_macs='[]'
for ((worker_index = 0; worker_index < NUTANIX_WORKERS; worker_index++)); do
  while :; do
    mac_bytes=$(od -An -N5 -tx1 /dev/urandom | tr -d '[:space:]')
    if [[ ${#mac_bytes} -ne 10 ]]; then
      echo "Could not generate a worker MAC address."
      exit 1
    fi
    worker_mac="02:${mac_bytes:0:2}:${mac_bytes:2:2}:${mac_bytes:4:2}:${mac_bytes:6:2}:${mac_bytes:8:2}"
    if ! jq -e --arg mac "$worker_mac" 'any(.[]; .mac == $mac)' <<<"$worker_macs" >/dev/null; then
      break
    fi
  done
  worker_macs=$(jq -c --arg name "$CLUSTER_NAME-worker-$worker_index" --arg mac "$worker_mac" \
    '. + [{name:$name,mac:$mac}]' <<<"$worker_macs")
done
umask 077
printf '%s\n' "$worker_macs" > "$worker_macs_file"

for ((worker_index = 0; worker_index < NUTANIX_WORKERS; worker_index++)); do
  worker_mac=$(jq -r --argjson index "$worker_index" '.[$index].mac' "$worker_macs_file")
  cat > "${temp_dir}/nmstateconfig.yaml" <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: NMStateConfig
metadata:
  name: "${INFRAENV_NAME}-worker-${worker_index}"
  namespace: "${AGENT_NAMESPACE}"
  labels:
    ${RUN_LABEL_KEY}: "${CLUSTER_NAME}"
    ${NETWORK_CONFIG_LABEL_KEY}: "${INFRAENV_NAME}"
spec:
  interfaces:
  - name: eth0
    macAddress: "${worker_mac}"
  config:
    interfaces:
    - name: eth0
      type: ethernet
      state: up
      mac-address: "${worker_mac}"
      ipv4:
        enabled: true
        dhcp: true
        auto-dns: false
      ipv6:
        enabled: false
    dns-resolver:
      config:
        server:
        - "${worker_dns_ip}"
EOF
  oc create -f "${temp_dir}/nmstateconfig.yaml"
done

cat > "${temp_dir}/nodepool-selector.yaml" <<EOF
spec:
  replicas: 0
  platform:
    agent:
      agentLabelSelector:
        matchLabels:
          ${RUN_LABEL_KEY}: "${CLUSTER_NAME}"
EOF
oc patch nodepool "${CLUSTER_NAME}" -n local-cluster --type=merge \
  --patch-file="${temp_dir}/nodepool-selector.yaml"

cat > "${temp_dir}/infraenv.yaml" <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: "${INFRAENV_NAME}"
  namespace: "${AGENT_NAMESPACE}"
  labels:
    ${RUN_LABEL_KEY}: "${CLUSTER_NAME}"
spec:
  cpuArchitecture: x86_64
  pullSecretRef:
    name: "${PULL_SECRET_NAME}"
  sshAuthorizedKey: |-
$(sed 's/^/    /' "${ssh_key_file}")
  agentLabels:
    ${RUN_LABEL_KEY}: "${CLUSTER_NAME}"
  nmStateConfigLabelSelector:
    matchLabels:
      ${NETWORK_CONFIG_LABEL_KEY}: "${INFRAENV_NAME}"
  proxy:
    httpProxy: "${PROXY_URL}"
    httpsProxy: "${PROXY_URL}"
    noProxy: "${no_proxy}"
EOF
oc apply -f "${temp_dir}/infraenv.yaml"
oc wait --namespace "${AGENT_NAMESPACE}" --for=condition=ImageCreated "infraenv/${INFRAENV_NAME}" --timeout=30m

iso_url=$(oc get infraenv "${INFRAENV_NAME}" -n "${AGENT_NAMESPACE}" -o go-template='{{with .status.isoDownloadURL}}{{.}}{{end}}')
if [[ -z "${iso_url}" ]]; then
  echo "InfraEnv ${INFRAENV_NAME} has no ISO download URL."
  exit 1
fi
printf '%s\n' "${PROXY_URL}" > "${SHARED_DIR}/nutanix_proxy_url"
printf '%s\n' "${no_proxy}" > "${SHARED_DIR}/nutanix_no_proxy"
