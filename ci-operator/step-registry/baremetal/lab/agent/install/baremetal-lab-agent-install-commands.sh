#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function mount_virtual_media() {
  local host="${1}"
  local iso_path="${2}"
  echo "Mounting the ISO image in #${host} via virtual media..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia "${host}" "${iso_path}"
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in #${host} via virtual media."
    touch /tmp/virtual_media_mount_failure
    return 1
  fi
  return 0
}

function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
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
}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml" >"${SHARED_DIR}"/host-id.txt
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="${INSTALL_DIR:-/tmp/installer}"
mkdir -p "${INSTALL_DIR}"

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

# We change the payload image to the one in the mirror registry only when the mirroring happens.
# For example, in the case of clusters using cluster-wide proxy, the mirroring is not required.
# To avoid additional params in the workflows definition, we check the existence of the mirror patch file.
if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-mirror.yaml.patch" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
fi

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
[ -f "${SHARED_DIR}/install-config.yaml" ] || echo "{}" >> "${SHARED_DIR}/install-config.yaml"
yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
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
"

echo "[INFO] Looking for patches to the install-config.yaml..."

shopt -s nullglob
for f in "${SHARED_DIR}"/*_patch_install_config.yaml;
do
  if test -f "${f}"
  then
      echo "[INFO] Applying patch file: $f"
      yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" "$f"
  fi
done

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
cp "${SHARED_DIR}/agent-config.yaml" "${INSTALL_DIR}/"

# From now on, we assume no more patches to the install-config.yaml are needed.
# Also, we assume that the agent-config.yaml is already in place in the SHARED_DIR.
# We can create the installation dir with the install-config.yaml and agent-config.yaml.
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml" || true
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/agent-config.yaml" > "${ARTIFACT_DIR}/agent-config.yaml" || true

### TODO check if we can support the following
### Create manifests
#echo "Creating manifests..."
#oinst agent create cluster-manifests

### Inject customized manifests
#echo -e "\nThe following manifests will be included at installation time:"
#find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)
#while IFS= read -r -d '' item
#do
#  manifest="$(basename "${item}")"
#  cp "${item}" "${INSTALL_DIR}/cluster-manifests/${manifest##manifest_}"
#done < <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)
gnu_arch=$(echo "$architecture" | sed 's/arm64/aarch64/;s/amd64/x86_64/;')

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

case "${BOOT_MODE}" in
"iso")
  ### Create ISO image
  echo -e "\nCreating image..."
  oinst agent create image
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the ISO image into the bastion host..."
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}/agent.$gnu_arch.iso" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}.${gnu_arch}.iso"
  echo -e "\nMounting the ISO image in the hosts via virtual media and powering on the hosts..."
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
      # Do not mount image to additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
      # on a single-arch payload migrated to a multi-arch cluster)
      continue
    fi
    if [ "${transfer_protocol_type}" == "cifs" ]; then
      IP_ADDRESS="$(dig +short "${AUX_HOST}")"
      iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}.${arch}.iso"
    else
      # Assuming HTTP or HTTPS
      iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/${CLUSTER_NAME}.${arch}.iso"
    fi
    mount_virtual_media "${host}" "${iso_path}"
  done

  wait
  if [ -f /tmp/virtual_media_mount_failed ]; then
    echo "Failed to mount the ISO image in one or more hosts"
    exit 1
  fi
;;
"pxe")
  ### Create pxe files
  echo -e "\nCreating PXE files..."
  oinst agent create pxe-files
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the PXE files into the bastion host..."
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/boot-artifacts/agent.*-vmlinuz* \
    "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/vmlinuz_${gnu_arch}"
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/boot-artifacts/agent.*-initrd* \
    "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/initramfs_${gnu_arch}.img"
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/boot-artifacts/agent.*-rootfs* \
    "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/rootfs-${gnu_arch}.img"
;;
*)
  echo "Unknown install mode: ${BOOT_MODE}"
  exit 1
esac

export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

echo -e "\nPreparing files for next steps in SHARED_DIR..."
cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeadmin-password" "${SHARED_DIR}/"
scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/auth/* "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/"

proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    # Do not power on the additional workers if we need to run them as day2 (e.g., to test single-arch clusters based
    # on a single-arch payload migrated to a multi-arch cluster)
    continue
  fi
  echo "Power on #${host} (${name})..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"
done

wait

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
echo -e "\nForcing 15min delay to allow instances to properly boot up (long PXE boot times & console-hook) - NOTE: unnecessary overtime will be reduced from total bootstrap time."
sleep 900
echo "Launching 'wait-for bootstrap-complete' installation step....."
# The installer uses the rendezvous IP for checking the bootstrap phase.
# The rendezvous IP is in the internal net in our lab.
# Let's use a proxy here as the internal net is not routable from the container running the installer.
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst agent wait-for bootstrap-complete 2>&1 &
if ! wait $!; then
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

update_image_registry &
echo -e "\nLaunching 'wait-for install-complete' installation step....."
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst agent wait-for install-complete &
if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi

echo "Ensure that all the cluster operators remain stable and ready until OCPBUGS-18658 is fixed."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=15m
