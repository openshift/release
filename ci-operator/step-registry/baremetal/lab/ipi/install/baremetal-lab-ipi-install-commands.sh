#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset
# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

export TF_LOG=DEBUG

function oinst() {
  /tmp/openshift-baremetal-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-10}
  local period=${3:-5}
  for i in $(seq 1 "${max_retries}") max; do
    if [ "${i}" == "max" ]; then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ "${ready_nodes}" == "${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

function update_image_registry() {
  # from OCP 4.14, the image-registry is optional, check if ImageRegistry capability is added
  knownCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}")
  if [[ ${knownCaps} =~ "ImageRegistry" ]]; then
      echo "knownCapabilities contains ImageRegistry"
      # check if ImageRegistry capability enabled
      enabledCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}")
        if [[ ! ${enabledCaps} =~ "ImageRegistry" ]]; then
            echo "ImageRegistry capability is not enabled, skip image registry configuration..."
            return 0
        fi
  fi
  while ! oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
                 --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'; do
    echo "Sleeping before retrying to patch the image registry config..."
    sleep 60
  done
  echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to go available..."
  oc wait co image-registry --for=condition=Available=True  --timeout=30m
  oc wait co image-registry  --for=condition=Progressing=False --timeout=10m
  sleep 60
  echo "$(date -u --rfc-3339=seconds) - Waits for kube-apiserver and openshift-apiserver to finish rolling out..."
  oc wait co kube-apiserver  openshift-apiserver --for=condition=Progressing=False  --timeout=30m
  oc wait co kube-apiserver  openshift-apiserver  --for=condition=Degraded=False  --timeout=1m
}
echo "[INFO] Initializing..."

PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

echo "[INFO] Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}..."
echo "[INFO] Extracting the baremetal-installer from ${MULTI_RELEASE_IMAGE}..."

# The extraction may be done from the release-multi-latest image, so that we can extract the openshift-baremetal-install
# based on the runner architecture. We might need to change this in the future if we want to ship different versions of
# the installer for different architectures in the same single-arch payload (and then support using a remote libvirt uri
# for the provisioning host).
oc adm release extract -a "$PULL_SECRET_PATH" "${MULTI_RELEASE_IMAGE}" \
  --command=openshift-baremetal-install --to=/tmp

# We change the payload image to the one in the mirror registry only when the mirroring happens.
# For example, in the case of clusters using cluster-wide proxy, the mirroring is not required.
# To avoid additional params in the workflows definition, we check the existence of the mirror patch file.
if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-mirror.yaml.patch" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
fi
file /tmp/openshift-baremetal-install
echo "[INFO] Set the worker architecture"
if [ -n "${ADDITIONAL_WORKER_ARCHITECTURE}" ] && [ "${ADDITIONAL_WORKERS_DAY2}" == "false" ]; then
  worker_arch=$(echo "${ADDITIONAL_WORKER_ARCHITECTURE}" | sed 's/aarch64/arm64/;s/x86_64/amd64/')
  workers=${ADDITIONAL_WORKERS}
  EXPECTED_NODES=$(( masters + workers ))
else
  worker_arch=${architecture}
fi

echo "[INFO] Processing the install-config.yaml..."
# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
   architecture: ${architecture}
   hyperthreading: Enabled
   name: master
   replicas: ${masters}
compute:
- architecture: ${worker_arch}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}
platform:
  baremetal:
    libvirtURI: >-
      qemu+ssh://root@${AUX_HOST}:$(sed 's/^[%]\?\([0-9]*\)[%]\?$/\1/' < "${CLUSTER_PROFILE_DIR}/provisioning-host-ssh-port-${architecture}")/system?keyfile=${CLUSTER_PROFILE_DIR}/ssh-key&no_verify=1&no_tty=1
    provisioningBridge: $(<"${SHARED_DIR}/provisioning_bridge")
    provisioningNetworkCIDR: $(<"${SHARED_DIR}/provisioning_network")
    externalMACAddress: $(<"${SHARED_DIR}/ipi_bootstrap_mac_address")
    hosts: []
"

# Copy provisioning-host-ssh-port-${architecture} to bastion host for use in cleanup
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/provisioning-host-ssh-port-${architecture}" "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/"

echo "[INFO] Processing the platform.baremetal.hosts list in the install-config.yaml..."
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not add additional workers if we need to run them as day2 (e.g., to test cluster-api)
    echo "{INFO} Additional worker ${name} will be added as day2 operation"
    continue
  fi
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "false" ]; then
    echo "Adding additional worker role for ${name}"
    node_role="worker"
  else
    echo "Setting worker role"
    node_role="${name%%-[0-9]*}"
  fi

  ADAPTED_YAML="
  name: ${name}
  role: ${node_role}
  bootMACAddress: ${provisioning_mac}
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  bmc:
    address: ${bmc_scheme}://${bmc_address}${bmc_base_uri}
    username: ${bmc_user}
    password: ${bmc_pass}
  networkConfig:
    interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: ${ipv4_enabled}
        dhcp: ${ipv4_enabled}
      ipv6:
        enabled: ${ipv6_enabled}
        dhcp: ${ipv6_enabled}
        autoconf: ${ipv6_enabled}
        auto-gateway: ${ipv6_enabled}
        auto-routes: ${ipv6_enabled}
        auto-dns: ${ipv6_enabled}
"
  # split the ipi_disabled_ifaces semi-comma separated list into an array
  IFS=';' read -r -a ipi_disabled_ifaces <<< "${ipi_disabled_ifaces}"
  for iface in "${ipi_disabled_ifaces[@]}"; do
    # Take care of the indentation when adding the disabled interfaces to the above yaml
    ADAPTED_YAML+="
    - name: ${iface}
      type: ethernet
      state: up
      ipv4:
        enabled: false
        dhcp: false
      ipv6:
        enabled: false
        dhcp: false
    "
  done
  # Patch the install-config.yaml by adding the given host to the hosts list in the platform.baremetal stanza
  yq --inplace eval-all 'select(fileIndex == 0).platform.baremetal.hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
    "$SHARED_DIR/install-config.yaml" - <<< "$ADAPTED_YAML"
  echo "Power off #${host} (${name}) and prepare host bmc conf for installation..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe" "no_power_on"
done

echo "[INFO] Looking for patches to the install-config.yaml..."

shopt -s nullglob
for f in "${SHARED_DIR}"/*_patch_install_config.yaml;
do
  echo "[INFO] Applying patch file: $f"
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" "$f"
done

for f in "${SHARED_DIR}"/*_append.patch_install_config.yaml;
do
  echo "[INFO] Appending patch file: $f"
  yq --inplace eval-all 'select(fileIndex == 0) *+ select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" "$f"
done

mkdir -p "${INSTALL_DIR}"
cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
# From now on, we assume no more patches to the install-config.yaml are needed.
# We can create the installation dir with the manifests and, finally, the ignition configs

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

# Also get a sanitized copy of the install-config.yaml as an artifact for debugging purposes
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml"

### Create manifests
echo "[INFO] Creating manifests..."
oinst create manifests

# Enable BMO to watch all namespaces if CAPI is enabled
if [[ "$ENABLE_CAPI" == "true" ]]; then
    sed -i 's/watchAllNamespaces: false/watchAllNamespaces: true/' "${INSTALL_DIR}/openshift/99_baremetal-provisioning-config.yaml"
fi

### Inject customized manifests
echo -e "\n[INFO] The following manifests will be included at installation time:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)
while IFS= read -r -d '' item
do
  manifest="$(basename "${item}")"
  cp "${item}" "${INSTALL_DIR}/manifests/${manifest##manifest_}"
done < <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

### Create Ignition configs
echo -e "\n[INFO] Creating Ignition configs..."
oinst create ignition-configs
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

echo -e "\n[INFO] Preparing files for next steps in SHARED_DIR..."
cp "${INSTALL_DIR}/metadata.json" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeadmin-password" "${SHARED_DIR}/"
scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/auth/* "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

# The installer's terraform template using the ironic provider needs to reach the ironic endpoint in the bootstrap VM
# to create the ironic nodes. The ironic endpoint's address is the API VIP, which is in the internal net in our lab.
# Let's use a proxy here as the internal net is not routable from the container running the installer.
proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
http_proxy=${proxy} https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst create cluster &

if ! wait $!; then
  exit 1
fi
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

echo -e "\n[INFO] Launching 'wait-for install-complete' installation step again....."
oinst wait-for install-complete &
if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi

# Additional check to wait for all the nodes to be ready. Especially important
# for multi-arch compute nodes clusters with mixed arch nodes.
if [ "${ADDITIONAL_WORKERS_DAY2}" == "false" ]; then
  echo -e "\nWaiting for all the nodes to be ready..."
  wait_for_nodes_readiness ${EXPECTED_NODES}
fi
update_image_registry

touch  "${SHARED_DIR}/success"
touch /tmp/install-complete
# Save console URL in `console.url` file so that ci-chat-bot could report success
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
# Password for the cluster gets leaked in the installer logs and hence removing them before saving in the artifacts.
sed 's/password: .*/password: REDACTED"/g' \
  ${INSTALL_DIR}/.openshift_install.log > "${ARTIFACT_DIR}"/.openshift_install.log
