#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure hostname can be found
HOSTNAME="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

trap 'prepare_next_steps' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

function save_credentials () {
  # Save credentials for diagnostic steps going forward
  echo "Saving authentication files for next steps..."
  cp /tmp/metadata.json ${SHARED_DIR}
  cp /tmp/auth/kubeconfig ${SHARED_DIR}
  cp /tmp/auth/kubeadmin-password ${SHARED_DIR}
}

function prepare_next_steps () {
  EXIT_CODE=$?
  echo ${EXIT_CODE} > "${SHARED_DIR}/install-status.txt"
  if [[ ${EXIT_CODE} != 0 ]]; then
    exit ${EXIT_CODE}
  fi
  set +e
  echo "Setup phase finished, prepare env for next steps"
  # Password for the cluster gets leaked in the installer logs and hence removing them.
  sed -i 's/password: .*/password: REDACTED"/g' /tmp/.openshift_install.log
  cp /tmp/.openshift_install.log "${ARTIFACT_DIR}"/.openshift_install.log
  save_credentials
  set -e
}

echo "FIPS_ENABLED = $FIPS_ENABLED"  # Delete before merge
if [ "${FIPS_ENABLED:-false}" = "true" ]; then
  echo "Ignoring host encryption validation for FIPS testing..."
  export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

# download the correct openshift-install from the payload
oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_TARGET}" \
  --command=openshift-install --to=/tmp

CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
OCPINSTALL='/tmp/openshift-install'
RHCOS_VERSION=$(${OCPINSTALL} coreos print-stream-json | yq-v4 -oy ".architectures.${ARCH}.artifacts.qemu.release")
QCOW_URL=$(${OCPINSTALL} coreos print-stream-json | yq-v4 -oy ".architectures.${ARCH}.artifacts.qemu.formats[\"qcow2.gz\"].disk.location")
VOLUME_NAME="ocp-${BRANCH}-rhcos-${RHCOS_VERSION}-qemu.${ARCH}.qcow2"
# All virsh commands need to be run on the hypervisor
LIBVIRT_CONNECTION="qemu+tcp://${HOSTNAME}/system"
# Simplify the virsh command
VIRSH="mock-nss.sh virsh --connect ${LIBVIRT_CONNECTION}"

# TODO: Update this to specify a different storage pool for each openshift version (4.16, 4.15, etc)
# Only create the storage pool if there isn't one already...
if [[ $(${VIRSH} pool-list | grep ${POOL_NAME}) ]]; then
  echo "Storage pool ${POOL_NAME} already exists. Skipping..."
else
  ${VIRSH} pool-define-as \
    --name ${POOL_NAME} \
    --type dir \
    --target ${LIBVIRT_IMAGE_PATH}
  ${VIRSH} pool-autostart ${POOL_NAME}
  ${VIRSH} pool-start ${POOL_NAME}
fi

# Check if we need to update the source volume
CURRENT_SOURCE_VOLUME=$(${VIRSH} vol-list --pool ${POOL_NAME} | grep "ocp-${BRANCH}-rhcos" | awk '{ print $1 }' || true)
echo "Current source volume name: ${CURRENT_SOURCE_VOLUME}"
echo "New source volume name: ${VOLUME_NAME}"

if [[ "${CURRENT_SOURCE_VOLUME}" != "${VOLUME_NAME}" ]]; then
  # Delete the old source volume
  if [[ ! -z "${CURRENT_SOURCE_VOLUME}" ]]; then
    echo "Deleting old source volume: '${CURRENT_SOURCE_VOLUME}'"
    ${VIRSH} vol-delete --pool ${POOL_NAME} ${CURRENT_SOURCE_VOLUME}
  fi

  # Download the new qcow image
  curl -L "${QCOW_URL}" | gunzip -c > /tmp/${VOLUME_NAME} || true

  # Resize the qemu to match the volume capacity
  qemu-img resize /tmp/${VOLUME_NAME} ${VOLUME_CAPACITY}

  # Create the new source volume
  ${VIRSH} vol-create-as \
    --name ${VOLUME_NAME} \
    --pool ${POOL_NAME} \
    --format qcow2 \
    --capacity ${VOLUME_CAPACITY}

  # Upload the qcow image to the source volume
  ${VIRSH} vol-upload \
    --vol ${VOLUME_NAME} \
    --pool ${POOL_NAME} \
    /tmp/${VOLUME_NAME}
fi

# Check for the node tuning yaml config, and save it in the installation directory
NODE_TUNING_YAML="${SHARED_DIR}/99-sysctl-worker.yaml"
if [ -f "${NODE_TUNING_YAML}" ]; then
  echo "Saving ${NODE_TUNING_YAML} to /tmp"
  cp ${NODE_TUNING_YAML} /tmp
fi

# Check for the etcd on ramdisk yaml config, and save it in the installation directory
ETCD_RAMDISK_YAML="${SHARED_DIR}/manifest_etcd-on-ramfs-mc.yml"
if [ -f "${ETCD_RAMDISK_YAML}" ]; then
  echo "Saving ${ETCD_RAMDISK_YAML} to /tmp"
  cp ${ETCD_RAMDISK_YAML} /tmp
fi

# Generating ignition configs
cp ${SHARED_DIR}/install-config.yaml /tmp
${OCPINSTALL} create ignition-configs --dir /tmp

save_credentials

# Create ignition volumes and upload the ignition configs
for IGNITION_TYPE in bootstrap master worker; do
  NAME=${LEASED_RESOURCE}-${IGNITION_TYPE}-ignition-volume

  ${VIRSH} vol-create-as \
    --name ${NAME} \
    --pool ${POOL_NAME} \
    --format raw \
    --capacity 1M

  ${VIRSH} vol-upload \
    --vol ${NAME} \
    --pool ${POOL_NAME} \
    /tmp/${IGNITION_TYPE}.ign
done

clone_volume () {
  if [ -z $1 ]; then
    echo "Must specify a name for the cloned volume..."
    exit 1
  fi

  ${VIRSH} vol-clone \
    --pool ${POOL_NAME} \
    --vol ${VOLUME_NAME} \
    --newname ${1}
}

create_vm () {
  # 1 = vm name, 2 = mac address, 3 = ignition config type
  if [[ -z ${1} || -z ${2} || -z ${3} ]]; then
    echo "Domain Name, MAC Address, or Ignition Type not specified..."
    echo "Domain Name: $1"
    echo "MAC Address: $2"
    echo "Ignition Type: $3"
    exit 1
  fi

  NAME=${1}
  MAC_ADDRESS=${2}
  IGNITION_VOLUME=${LEASED_RESOURCE}-${3}-ignition-volume

  virt-install \
    --connect ${LIBVIRT_CONNECTION} \
    --name ${NAME} \
    --memory ${DOMAIN_MEMORY} \
    --vcpus ${DOMAIN_VCPUS} \
    --network network=${CLUSTER_NAME},mac=${MAC_ADDRESS} \
    --disk="vol=${POOL_NAME}/${NAME}-volume" \
    --osinfo ${VIRT_INSTALL_OSINFO} \
    --graphics=none \
    --import \
    --noautoconsole \
    --disk vol=${POOL_NAME}/${IGNITION_VOLUME},format=raw,readonly=on,serial=ignition,startup_policy=optional
}

# Create the bootstrap node.
NODE="${LEASED_RESOURCE}-bootstrap"
MAC_ADDRESS=$(leaseLookup "bootstrap[0].mac")
clone_volume ${NODE}-volume
create_vm ${NODE} ${MAC_ADDRESS} bootstrap

# Create the control plane nodes.
for (( i=0; i<=${CONTROL_COUNT}-1; i++ )); do
  NODE="${LEASED_RESOURCE}-control-${i}"
  MAC_ADDRESS=$(leaseLookup "control-plane[$i].mac")
  clone_volume ${NODE}-volume
  create_vm ${NODE} ${MAC_ADDRESS} master
done

# Create the compute nodes.
for (( i=0; i<=${COMPUTE_COUNT}-1; i++ )); do
  NODE="${LEASED_RESOURCE}-compute-${i}"
  MAC_ADDRESS=$(leaseLookup "compute[$i].mac")
  clone_volume ${NODE}-volume
  create_vm ${NODE} ${MAC_ADDRESS} worker
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

${OCPINSTALL} --dir "/tmp" wait-for bootstrap-complete &
# TODO: collect logs in case of failure
wait "$!"

# Sleep between destroy and undefine to allow for a slight destroy lag
${VIRSH} destroy "${LEASED_RESOURCE}-bootstrap"
sleep 1s
${VIRSH} undefine "${LEASED_RESOURCE}-bootstrap"

echo "Approving pending CSRs"
approve_csrs () {
  oc version --client
  while true; do
    if [[ ! -f /tmp/install-complete ]]; then
      # even if oc get csr fails continue
      oc get csr -ojson | yq-v4 -oy '.items[] | select(.status | length == 0) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}
approve_csrs &

# Add a small buffer before waiting for install completion
sleep 5m

set +x
echo "Completing UPI setup"
${OCPINSTALL} --dir="/tmp" wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

# Check for image registry availability
for i in {1..10}; do
  count=$(oc get configs.imageregistry.operator.openshift.io/cluster --no-headers | wc -l)
  echo "Image registry count: ${count}"
  if [[ ${count} -gt 0 ]]; then
    break
  fi
  sleep 30
done

# Patch the image registry
echo "Patching image registry..."
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"emptyDir":{}}, "managementState": "Managed"}}'
sleep 60
for i in {1..30}; do
  READY_REPLICAS=$(oc get deployment -n openshift-image-registry -oyaml image-registry | yq-v4 -oy ".status.readyReplicas")
  TOTAL_REPLICAS=$(oc get deployment -n openshift-image-registry -oyaml image-registry | yq-v4 -oy ".status.replicas")
  if [[ "${READY_REPLICAS}" == "${TOTAL_REPLICAS}" ]]; then
    echo "Patched successfully!"
    break
  fi
  sleep 15
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

touch /tmp/install-complete
