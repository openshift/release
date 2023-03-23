#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

[ -z "${WORKERS}" ] && { echo "\$WORKERS is not filled. Failing."; exit 1; }
[ -z "${MASTERS}" ] && { echo "\$MASTERS is not filled. Failing."; exit 1; }

third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

export HOME=/tmp

pull_secret_path=${CLUSTER_PROFILE_DIR}/pull-secret
build01_secrets="/var/run/vault/secrets/.dockerconfigjson"
extract_build01_auth=$(jq -c '.auths."registry.apps.build01-us-west-2.vmc.ci.openshift.org"' ${build01_secrets})
final_pull_secret=$(jq -c --argjson auth "$extract_build01_auth" '.auths["registry.apps.build01-us-west-2.vmc.ci.openshift.org"] += $auth' "${pull_secret_path}")

echo "${final_pull_secret}" >> "${SHARED_DIR}"/pull-secrets
echo "$(date -u --rfc-3339=seconds) - Creating reusable variable files..."
# Create base-domain.txt
echo "vmc-ci.devcluster.openshift.com" > "${SHARED_DIR}"/base-domain.txt
base_domain=$(<"${SHARED_DIR}"/base-domain.txt)

echo "192.168.${third_octet}.4" >> "${SHARED_DIR}"/vips.txt
echo "192.168.${third_octet}.4" >> "${SHARED_DIR}"/vips.txt
echo "192.168.${third_octet}.0/25" >> "${SHARED_DIR}"/machinecidr.txt

echo "Reserved the following IP addresses..."
cat "${SHARED_DIR}"/vips.txt

machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

pull_secret=$(<"${SHARED_DIR}/pull-secrets")

# Create cluster-name.txt
echo "${NAMESPACE}-${JOB_NAME_HASH}" > "${SHARED_DIR}"/cluster-name.txt
cluster_name=$(<"${SHARED_DIR}"/cluster-name.txt)

yq -i 'del(.pullSecret)' "${SHARED_DIR}/install-config.yaml"
cat >> "${SHARED_DIR}/install-config.yaml" << EOF
baseDomain: ${base_domain}
controlPlane:
  name: master
  replicas: ${MASTERS}
compute:
- name: worker
  replicas: ${WORKERS}
networking:
  machineNetwork:
  - cidr: ${machine_cidr}
platform:
  none: {}
pullSecret: >
  ${pull_secret}
EOF

# Create cluster-domain.txt
echo "${cluster_name}.${base_domain}" > "${SHARED_DIR}"/cluster-domain.txt

# select a hardware version for testing
hw_versions=(15 17 18 19)
hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % + hw_available_versions))
target_hw_version=${hw_versions[$selected_hw_version_index]}

echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >> "${SHARED_DIR}"/vsphere_context.sh

declare dns_server
source "${SHARED_DIR}/vsphere_context.sh"

agent_config="${SHARED_DIR}/agent-config.yaml"
touch "${SHARED_DIR}/agent-config.yaml"

echo "00:50:56:ac:b8:00" > "${SHARED_DIR}"/mac-address.txt
mac_address=$(<"${SHARED_DIR}"/mac-address.txt)
#create agent config file
cat > "$agent_config" << EOF
apiVersion: v1alpha1
kind: AgentConfig
rendezvousIP: 192.168.${third_octet}.4
hosts:
 - hostname: master-1
   role: master
   interfaces:
    - name: "ens32"
      macAddress: "${mac_address}"
   networkConfig:
    interfaces:
      - name: ens32
        type: ethernet
        state: up
        mac-address: "${mac_address}"
        ipv4:
          enabled: true
          address:
            - ip: 192.168.${third_octet}.4
              prefix-length: 25
          dhcp: false
    dns-resolver:
     config:
      server:
       - $dns_server
    routes:
     config:
       - destination: 0.0.0.0/0
         next-hop-address: 192.168.${third_octet}.1
         next-hop-interface: ens32
         table-id: 254
EOF
echo "Installing from initial release $RELEASE_IMAGE_LATEST"
oc adm release extract -a "$pull_secret_path" "$RELEASE_IMAGE_LATEST" \
   --command=openshift-install --to=/tmp

dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" \
    "${SHARED_DIR}"/{install-config.yaml,agent-config.yaml}

echo "Creating agent image..."
/tmp/openshift-install agent create image --dir="${dir}" --log-level debug &

if ! wait $!; then
  cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"
  exit 1
fi

curl -s -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz -o ${HOME}/glx.tar.gz && tar -C ${HOME} -xvf ${HOME}/glx.tar.gz govc && rm -f ${HOME}/glx.tar.gz

source "${SHARED_DIR}/govc.sh"

echo "agent.x86_64_${cluster_name}.iso" > "${SHARED_DIR}"/agent-iso.txt
agent_iso=$(<"${SHARED_DIR}"/agent-iso.txt)
declare vsphere_datastore
echo "uploading ${agent_iso} to iso-datastore.."
/tmp/govc datastore.upload -ds "${vsphere_datastore}" agent.x86_64.iso agent-installer-isos/"${agent_iso}" &

if ! wait $!; then
  echo "$(date -u --rfc-3339=seconds) - Failed to upload agent iso!"
  exit 1
fi

echo "Copying kubeconfig to the shared directory..."
cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeadmin-password" \
    "${dir}/auth/kubeconfig" \
    "${dir}/.openshift_install_state.json"
popd
