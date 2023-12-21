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
[ -z "${PROVISIONING_HOST}" ] && { echo "\$PROVISIONING_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export TF_LOG=DEBUG

function oinst() {
  /tmp/openshift-baremetal-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

function prepare_bmc() {
  local bmc_host="${1}"
  local bmc_port="${2}"
  local bmc_user="${3}"
  local bmc_pass="${4}"
  local ipxe_via_vmedia="${5}"
  local host="${bmc_port##1[0-9]}"
  host="${host##0}"
  # HPE iLO6 BMCs on RL300 do not have drivers for BCM5720 NICs, use vmedia to load ipxe.usb
  # See https://issues.redhat.com/browse/OCPQE-18370
  if [ "$ipxe_via_vmedia" == "true" ]; then
    echo "Host #$host will boot via ipxe on vmedia..."
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia.ipxe "${host}"
  else
    ipmitool -I lanplus -H "${bmc_host}" -p "${bmc_port}" \
      -U "$bmc_user" -P "$bmc_pass" \
      chassis bootparam set bootflag force_pxe options=PEF,watchdog,reset,power
  fi
  ipmitool -I lanplus -H "${bmc_host}" -p "${bmc_port}" \
    -U "$bmc_user" -P "$bmc_pass" \
    power off || echo "Already off"
}

function update_image_registry() {
  while ! oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
                 --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'; do
    echo "Sleeping before retrying to patch the image registry config..."
    sleep 60
  done
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
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-baremetal-install --to=/tmp

# We change the payload image to the one in the mirror registry only when the mirroring happens.
# For example, in the case of clusters using cluster-wide proxy, the mirroring is not required.
# To avoid additional params in the workflows definition, we check the existence of the ICSP patch file.
if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-icsp.yaml.patch" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
fi
file /tmp/openshift-baremetal-install

echo "[INFO] Processing the install-config.yaml..."
# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  machineNetwork:
  - cidr: ${INTERNAL_NET_CIDR}
controlPlane:
   architecture: ${architecture}
   hyperthreading: Enabled
   name: master
   replicas: ${masters}
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}
platform:
  baremetal:
    libvirtURI: >-
      qemu+ssh://root@${PROVISIONING_HOST}/system?keyfile=${CLUSTER_PROFILE_DIR}/ssh-key&no_verify=1&no_tty=1
    apiVIP: $(yq ".api_vip" "${SHARED_DIR}/vips.yaml")
    ingressVIP: $(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")
    provisioningBridge: $(<"${SHARED_DIR}/provisioning_bridge")
    provisioningNetworkCIDR: $(<"${SHARED_DIR}/provisioning_network")
    hosts: []
"

echo "[INFO] Processing the platform.baremetal.hosts list in the install-config.yaml..."
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  ADAPTED_YAML="
  name: ${name}
  role: ${name%%-[0-9]*}
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
        enabled: true
        dhcp: true
      ipv6:
        enabled: true
        dhcp: true
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
  prepare_bmc "${AUX_HOST}" "${bmc_forwarded_port}" "${bmc_user}" "${bmc_pass}"
done

mkdir -p "${INSTALL_DIR}"
cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
# From now on, we assume no more patches to the install-config.yaml are needed.
# We can create the installation dir with the manifests and, finally, the ignition configs

# Also get a sanitized copy of the install-config.yaml as an artifact for debugging purposes
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml"

### Create manifests
echo "[INFO] Creating manifests..."
oinst create manifests

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

update_image_registry &
echo -e "\n[INFO] Launching 'wait-for install-complete' installation step again....."
oinst wait-for install-complete &
if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi

touch  "${SHARED_DIR}/success"
touch /tmp/install-complete
# Save console URL in `console.url` file so that ci-chat-bot could report success
echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
# Password for the cluster gets leaked in the installer logs and hence removing them before saving in the artifacts.
sed 's/password: .*/password: REDACTED"/g' \
  ${INSTALL_DIR}/.openshift_install.log > "${ARTIFACT_DIR}"/.openshift_install.log
