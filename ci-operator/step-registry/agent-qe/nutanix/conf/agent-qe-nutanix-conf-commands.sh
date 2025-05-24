#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Failed to acquire lease"
    exit 1
fi

[ -z "${WORKERS}" ] && {
  echo "\$WORKERS is not filled. Failing."
  exit 1
}
[ -z "${MASTERS}" ] && {
  echo "\$MASTERS is not filled. Failing."
  exit 1
}

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
  NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
  NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi

declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
declare one_net_mode_network_name
# shellcheck source=/dev/random
source "${NUTANIX_AUTH_PATH}"
sed -i 's/"//g' "${SHARED_DIR}/nutanix_context.sh"
source "${SHARED_DIR}/nutanix_context.sh"

echo "$(date -u --rfc-3339=seconds) - Getting PE UUID"

pc_url="https://${prism_central_host}:${prism_central_port}"
api_ep="${pc_url}/api/nutanix/v3/clusters/list"
un="${prism_central_username}"
pw="${prism_central_password}"

echo "$(date -u --rfc-3339=seconds) - Getting Subnet UUID"
api_ep="${pc_url}/api/nutanix/v3/subnets/list"
data="{
  \"kind\": \"subnet\"
}"

subnet_name="${LEASED_RESOURCE}"
slice_number=${LEASED_RESOURCE: -1}

if [[ -n "${one_net_mode_network_name:-}" ]]; then
  subnet_name="${one_net_mode_network_name}"
fi

subnets_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @-<<<"${data}")
subnet_uuid=$(echo "${subnets_json}" | jq ".entities[] | select (.spec.name == \"${subnet_name}\") | .metadata.uuid ")

if [[ -z "${subnet_uuid}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Cannot get Subnet UUID"
  exit 1
fi

subnet_ip=$(echo "${subnets_json}" | jq ".entities[] | select(.spec.name==\"${subnet_name}\") | .spec.resources.ip_config.subnet_ip")

if [[ -z "${subnet_ip}" ]]; then
  echo "$(date -u --rfc-3399=seconds) - Cannot get VIP for API"
  exit 1
fi

RENDEZVOUS_IP=$(echo "${subnet_ip}" | sed 's/"//g' | awk -v num="${slice_number}" -F. '{printf "%d.%d.%d.%d", $1, $2, $3, 10 + num * 2 + 10}')

echo "export RENDEZVOUS_IP=$RENDEZVOUS_IP" >>"${SHARED_DIR}/nutanix_context.sh"
echo "${RENDEZVOUS_IP}" >"${SHARED_DIR}"/node-zero-ip.txt

cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${RENDEZVOUS_IP}
EOF

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
echo "$CLUSTER_NAME" >>"${SHARED_DIR}"/cluster-name.txt

declare -a hostnames=()
for ((i = 0; i < MASTERS; i++)); do
  hostname="${CLUSTER_NAME}-master-$i"
  echo "$hostname" >>"${SHARED_DIR}"/hostnames.txt
  hostnames+=("${hostname}")
done

for ((i = 0; i < WORKERS; i++)); do
  hostname="${CLUSTER_NAME}-worker-$i"
  echo "$hostname" >>"${SHARED_DIR}"/hostnames.txt
  hostnames+=("${hostname}")
done

pull_secret_path=${CLUSTER_PROFILE_DIR}/pull-secret
build01_secrets="/var/run/vault/secrets/.dockerconfigjson"
extract_build01_auth=$(jq -c '.auths."registry.build01.ci.openshift.org"' ${build01_secrets})
final_pull_secret=$(jq -c --argjson auth "$extract_build01_auth" '.auths["registry.build01.ci.openshift.org"] += $auth' "${pull_secret_path}")

touch "${SHARED_DIR}"/pull-secrets
echo "${final_pull_secret}" >> "${SHARED_DIR}"/pull-secrets
pull_secret=$(<"${SHARED_DIR}"/pull-secrets)

# Add build01 secrets if the mirror registry secrets are not available.
if [ ! -f "${SHARED_DIR}/pull_secret_ca.yaml.patch" ]; then
  yq -i 'del(.pullSecret)' "${SHARED_DIR}/install-config.yaml"
  cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
pullSecret: >
  ${pull_secret}
EOF
fi

yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<<"
baseDomain: ${BASE_DOMAIN}
controlPlane:
  name: master
  replicas: ${MASTERS}
compute:
- name: worker
  replicas: ${WORKERS}
platform:
  nutanix:
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
    prismCentral:
      endpoint:
        address: ${NUTANIX_HOST}
        port: ${NUTANIX_PORT}
      password: ${NUTANIX_PASSWORD}
      username: ${NUTANIX_USERNAME}
    prismElements:
    - endpoint:
        address: ${PE_HOST}
        port: ${PE_PORT}
      uuid: ${PE_UUID}
    subnetUUIDs:
    - ${subnet_uuid}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
"

if [ "${MASTERS}" -eq 1 ]; then
  sed -i "s|^export API_VIP=.*|export API_VIP='${RENDEZVOUS_IP}'|" "${SHARED_DIR}/nutanix_context.sh"
  sed -i "s|^export INGRESS_VIP=.*|export INGRESS_VIP='${RENDEZVOUS_IP}'|" "${SHARED_DIR}/nutanix_context.sh"
  yq --inplace 'del(.platform)' "${SHARED_DIR}"/install-config.yaml
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<<"
platform:
  none: {}
"
fi