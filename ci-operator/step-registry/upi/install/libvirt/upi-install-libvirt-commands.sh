#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

INSTALL_DIR=/tmp

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

# ensure hostname can be found
HOSTNAME="$(leaseLookup 'hostname')"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

function save_credentials () {
  # Save credentials for diagnostic steps going forward
  echo "Saving authentication files for next steps..."
  if [ -f ${INSTALL_DIR}/metadata.json ]; then
    cp ${INSTALL_DIR}/metadata.json ${SHARED_DIR}
  fi
  cp ${INSTALL_DIR}/auth/kubeconfig ${SHARED_DIR}
  cp ${INSTALL_DIR}/auth/kubeadmin-password ${SHARED_DIR}
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
  sed -i 's/password: .*/password: REDACTED"/g' "${INSTALL_DIR}/.openshift_install.log"
  cp "${INSTALL_DIR}/.openshift_install.log" "${ARTIFACT_DIR}"/.openshift_install.log
  save_credentials
  set -e
}

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
  echo "Ignoring host encryption validation for FIPS testing..."
  export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

# download openshift-install from the payload
echo "Extracting openshift-install from the payload..."
oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_TARGET}" \
  --command=openshift-install --to="${INSTALL_DIR}"

CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
OCPINSTALL="${INSTALL_DIR}/openshift-install"
# All virsh commands need to be run on the hypervisor
LIBVIRT_CONNECTION="qemu+tcp://${HOSTNAME}/system"
# Simplify the virsh command
VIRSH="mock-nss.sh virsh --connect ${LIBVIRT_CONNECTION}"

# Only create the storage pool if there isn't one already...
if [[ $(${VIRSH} pool-list | grep ${POOL_NAME}) ]]; then
  echo "Storage pool ${POOL_NAME} already exists. Skipping..."
else
  if [[ $(${VIRSH} pool-list --all | grep ${POOL_NAME}) ]]; then
    echo "Storage pool ${POOL_NAME} already exists in inactive state. Deleting it.."
    ${VIRSH} pool-destroy "${POOL_NAME}"
    ${VIRSH} pool-undefine "${POOL_NAME}"
  fi
  echo "Creating storage pool..."
  ${VIRSH} pool-define-as \
    --name ${POOL_NAME} \
    --type dir \
    --target ${LIBVIRT_IMAGE_PATH}
  ${VIRSH} pool-autostart ${POOL_NAME}
  ${VIRSH} pool-start ${POOL_NAME}
fi

# Move the install config to the install directory
echo "Move the install config to the install directory..."
cp ${SHARED_DIR}/install-config.yaml ${INSTALL_DIR}

if [ "$INSTALLER_TYPE" == "agent" ]; then
  cp ${SHARED_DIR}/agent-config.yaml ${INSTALL_DIR}
  ${OCPINSTALL} --dir ${INSTALL_DIR} agent create pxe-files
  save_credentials

  # These vars are used for local look-ups only
  BOOT_ARTIFACTS_LOCAL_DIR="${INSTALL_DIR}/boot-artifacts"
  BOOT_ARTIFACTS_POOL_NAME=${POOL_NAME}
  INITRD=agent.${ARCH}-initrd.img
  ROOTFS=agent.${ARCH}-rootfs.img

  # These vars are exported since we will used them in the domain.xml creation
  export KERNEL_NAME="${LEASED_RESOURCE}-kernel"
  export INITRD_NAME="${LEASED_RESOURCE}-initrd"
  export ROOTFS_NAME="${LEASED_RESOURCE}-rootfs"
  export BOOT_ARTIFACTS_PATH="${LIBVIRT_IMAGE_PATH}"

  # The name of the kernel artifact depends on the arch
  if [ "$ARCH" == "s390x" ]; then
    if echo ${BRANCH} | sed 's/.* //;q' | awk -F. '{ if ($1 > 4 || ($1 >= 4 && $2 >= 19 )) { exit 0 } else {exit 1} }'; then
      KERNEL="agent.${ARCH}-vmlinuz"
    else
      KERNEL="agent.${ARCH}-kernel.img"
    fi

    # Merge the initrds together and rename them so they can be found on the remote host; for some reason, order matters when catting these together
    cat "${BOOT_ARTIFACTS_LOCAL_DIR}/${ROOTFS}" "${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD}" > "${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD_NAME}"
  elif [ "$ARCH" == "ppc64le" ]; then
    KERNEL="agent.${ARCH}-vmlinuz"

    # Renamed the initrd so we can find it on the remote host
    mv "${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD}" "${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD_NAME}"
  else
    echo "Unrecognized architecture: $ARCH"
    exit 1
  fi

  # Rename kernel and rootfs so we can find them on the remote host
  mv "${BOOT_ARTIFACTS_LOCAL_DIR}/${KERNEL}" "${BOOT_ARTIFACTS_LOCAL_DIR}/${KERNEL_NAME}"
  mv "${BOOT_ARTIFACTS_LOCAL_DIR}/${ROOTFS}" "${BOOT_ARTIFACTS_LOCAL_DIR}/${ROOTFS_NAME}"

  # Show all created boot artifacts  
  ls -l ${BOOT_ARTIFACTS_LOCAL_DIR}

  if [[ ! -f "${BOOT_ARTIFACTS_LOCAL_DIR}/${KERNEL_NAME}" ]]; then
      echo "Agent installer couldn't create kernel image, exiting."
      exit 1
  fi
  if [[ ! -f "${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD_NAME}" ]]; then
      echo "Agent installer couldn't create combined rootfs and initrd image, exiting."
      exit 1
  fi

  # Upload the kernel to remote host
  ${VIRSH} vol-delete ${KERNEL_NAME} --pool ${BOOT_ARTIFACTS_POOL_NAME} || true
  ${VIRSH} vol-create-as \
      --name ${KERNEL_NAME} \
      --pool ${BOOT_ARTIFACTS_POOL_NAME} \
      --format raw \
      --capacity "$(wc -c < ${BOOT_ARTIFACTS_LOCAL_DIR}/${KERNEL_NAME})"
  ${VIRSH} vol-upload \
      --vol ${KERNEL_NAME} \
      --pool ${BOOT_ARTIFACTS_POOL_NAME} \
      --file ${BOOT_ARTIFACTS_LOCAL_DIR}/${KERNEL_NAME}

  # Upload the initrd to remote host
  ${VIRSH} vol-delete ${INITRD_NAME} --pool ${BOOT_ARTIFACTS_POOL_NAME} || true
  ${VIRSH} vol-create-as \
      --name ${INITRD_NAME} \
      --pool ${BOOT_ARTIFACTS_POOL_NAME} \
      --format raw \
      --capacity "$(wc -c < ${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD_NAME})"
  ${VIRSH} vol-upload \
      --vol ${INITRD_NAME} \
      --pool ${BOOT_ARTIFACTS_POOL_NAME} \
      --file ${BOOT_ARTIFACTS_LOCAL_DIR}/${INITRD_NAME}


  # On power, the rootfs needs to be staged for download via apache
  if [ "$ARCH" == "ppc64le" ]; then
      cat << EOF > ${INSTALL_DIR}/rootfs.xml
<volume>
  <name>${ROOTFS_NAME}</name>
  <capacity unit="bytes">$(wc -c < ${BOOT_ARTIFACTS_LOCAL_DIR}/${ROOTFS_NAME})</capacity>
  <target>
    <path>${ROOTFS_NAME}</path>
    <permissions>
      <mode>0644</mode>
      <owner>0</owner>
      <group>0</group>
      <label>system_u:object_r:virt_image_t:s0</label>
    </permissions>
  </target>
</volume>
EOF

      # The rootfs is created via xml because the CLI options don't allow us to specify the permissions mode
      cat ${INSTALL_DIR}/rootfs.xml
      
      echo "Uploading rootfs..."
      ${VIRSH} vol-delete ${ROOTFS_NAME} --pool ${HTTPD_POOL_NAME} || true
      ${VIRSH} vol-create --file ${INSTALL_DIR}/rootfs.xml --pool ${HTTPD_POOL_NAME}
      ${VIRSH} vol-upload \
        --vol ${ROOTFS_NAME} \
        --pool ${HTTPD_POOL_NAME} \
        --file ${BOOT_ARTIFACTS_LOCAL_DIR}/${ROOTFS_NAME}
  fi

  # Generate manifests for cluster modifications
  echo "Generating manifests..."
  ${OCPINSTALL} --dir "${INSTALL_DIR}" agent create cluster-manifests

else
  RHCOS_VERSION=$(${OCPINSTALL} coreos print-stream-json | yq-v4 -oy ".architectures.${ARCH}.artifacts.qemu.release")
  QCOW_URL=$(${OCPINSTALL} coreos print-stream-json | yq-v4 -oy ".architectures.${ARCH}.artifacts.qemu.formats[\"qcow2.gz\"].disk.location")
  VOLUME_NAME="ocp-${BRANCH}-rhcos-${RHCOS_VERSION}-qemu.${ARCH}.qcow2"
  DOWNLOAD_NEW_IMAGE=true

  # Check if we need to update the source volume
  for CURRENT_SOURCE_VOLUME in $(${VIRSH} vol-list --pool ${POOL_NAME} | grep "ocp-${BRANCH}-rhcos" | awk '{ print $1 }' || true); do
    if [[ "${CURRENT_SOURCE_VOLUME}" == "${VOLUME_NAME}" ]]; then
      DOWNLOAD_NEW_IMAGE=false
    # Delete the old source volume
    else
        echo "Deleting ${CURRENT_SOURCE_VOLUME} source volume..."
        ${VIRSH} vol-delete --pool ${POOL_NAME} ${CURRENT_SOURCE_VOLUME}
    fi
  done

  if [[ "${DOWNLOAD_NEW_IMAGE}" == true ]]; then
    # Download the new rhcos image
    echo "Downloading new rhcos image..."
    curl -L "${QCOW_URL}" | gunzip -c > ${INSTALL_DIR}/${VOLUME_NAME} || true

    # Resize the rhcos image to match the volume capacity
    echo "Resizing rhcos image to match volume capacity..."
    qemu-img resize ${INSTALL_DIR}/${VOLUME_NAME} ${VOLUME_CAPACITY}

    # Create the new source volume
    echo "Creating source volume..."
    ${VIRSH} vol-create-as \
      --name ${VOLUME_NAME} \
      --pool ${POOL_NAME} \
      --format qcow2 \
      --capacity ${VOLUME_CAPACITY} || echo "Volume ${VOLUME_NAME} already exists, proceed without creation"

    # Upload the rhcos image to the source volume
    echo "Uploading rhcos image to source volume..."
    ${VIRSH} vol-upload \
      --vol ${VOLUME_NAME} \
      --pool ${POOL_NAME} \
      ${INSTALL_DIR}/${VOLUME_NAME}
  fi

  # Generate manifests for cluster modifications
  echo "Generating manifests..."
  ${OCPINSTALL} --dir "${INSTALL_DIR}" create manifests
fi

# Check for the node tuning yaml config, and save it in the installation directory
NODE_TUNING_YAML="${SHARED_DIR}/99-sysctl-worker.yaml"
if [ -f "${NODE_TUNING_YAML}" ]; then
  echo "Saving ${NODE_TUNING_YAML} to the install directory..."
  cp ${NODE_TUNING_YAML} "${INSTALL_DIR}/manifests"
fi

# Sets up the chrony machineconfig for the worker nodes
CHRONY_WORKER_YAML="${SHARED_DIR}/99-chrony-worker.yaml"
if [ -f "${CHRONY_WORKER_YAML}" ]; then
  echo "Saving ${CHRONY_WORKER_YAML} to the install directory..."
  cp ${CHRONY_WORKER_YAML} "${INSTALL_DIR}/manifests"
fi

# Sets up the chrony machineconfig for the master nodes
CHRONY_MASTER_YAML="${SHARED_DIR}/99-chrony-master.yaml"
if [ -f "${CHRONY_MASTER_YAML}" ]; then
  echo "Saving ${CHRONY_MASTER_YAML} to the install directory..."
  cp ${CHRONY_MASTER_YAML} "${INSTALL_DIR}/manifests"
fi

# Check for the etcd on ramdisk yaml config, and save it in the installation directory
ETCD_RAMDISK_YAML="${SHARED_DIR}/manifest_etcd-on-ramfs-mc.yml"
if [ -f "${ETCD_RAMDISK_YAML}" ]; then
  echo "Saving ${ETCD_RAMDISK_YAML} to the install directory..."
  cp ${ETCD_RAMDISK_YAML} "${INSTALL_DIR}/manifests"
fi

# Check for static pod controller degraded yaml config, and save it in the installation directory
STATIC_POD_DEGRADED_YAML="${SHARED_DIR}/manifest_static-pod-check-workaround-master-mc.yml"
if [ -f "${STATIC_POD_DEGRADED_YAML}" ]; then
  echo "Saving ${STATIC_POD_DEGRADED_YAML} to the install directory..."
  cp ${STATIC_POD_DEGRADED_YAML} "${INSTALL_DIR}/manifests"
fi

# Check for kdump worker yaml config, and save it in the installation directory
KDUMP_WORKER_YAML="${SHARED_DIR}/manifest_99_worker_kdump.yml"
if [ -f "${KDUMP_WORKER_YAML}" ]; then
  echo "Saving ${KDUMP_WORKER_YAML} to the install directory..."
  cp ${KDUMP_WORKER_YAML} /tmp/manifests
fi

if [ "${INSTALLER_TYPE}" == "default" ]; then
  # Generating ignition configs
  echo "Generating ignition configs..."
  ${OCPINSTALL} create ignition-configs --dir ${INSTALL_DIR}

  # Create ignition volumes and upload the ignition configs
  for IGNITION_TYPE in bootstrap master worker; do
    NAME=${LEASED_RESOURCE}-${IGNITION_TYPE}-ignition-volume

    echo "Creating ${IGNITION_TYPE} ignition volume..."
    ${VIRSH} vol-create-as \
      --name ${NAME} \
      --pool ${POOL_NAME} \
      --format raw \
      --capacity 1M

    echo "Uploading ${IGNITION_TYPE}.ign to ${NAME} volume..."
    ${VIRSH} vol-upload \
      --vol ${NAME} \
      --pool ${POOL_NAME} \
      ${INSTALL_DIR}/${IGNITION_TYPE}.ign
  done
fi

# Save credentials now that we've finished the install pre-requisites.
save_credentials

restart_nodes () {
  echo "Starting node monitor to restart nodes post-install."
  GUESTS_RESTARTED=0
  TOTAL_GUESTS=$((${CONTROL_COUNT:-0} + ${COMPUTE_COUNT:-0}))
  while [ $GUESTS_RESTARTED -lt $TOTAL_GUESTS ]
  do
     INSTALLED=$(${VIRSH} list --all | grep "${LEASED_RESOURCE}" | grep "shut off" | awk -F' ' '{print $2}' || true)
     for i in $INSTALLED; do
       GUESTS_RESTARTED=$(($GUESTS_RESTARTED + 1))
       ${VIRSH} start $i
       echo "Restarted ${GUESTS_RESTARTED}/${TOTAL_GUESTS}"
     done
     sleep 30s
  done
  echo "Restarted all nodes after initial boot"
}

clone_volume () {
  if [ -z $1 ]; then
    echo "Must specify a name for the cloned volume..."
    exit 1
  fi

  echo "Cloning ${VOLUME_NAME} volume as ${1} volume..."
  ${VIRSH} vol-clone \
    --pool ${POOL_NAME} \
    --vol ${VOLUME_NAME} \
    --newname ${1}
}

create_node () {
  # 1 = node name, 2 = mac address, 3 = ignition config type
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

  if [ "$INSTALLER_TYPE" == "agent" ]; then
    # Calculate the last dynamic vars
    DOMAIN_UUID="$(uuidgen)"
    EXTRA_ARGS="rw rd.neednet=1 nameserver=192.168.$(leaseLookup 'subnet').1 ip=dhcp ignition.firstboot ignition.platform.id=metal"

    if [[ "$ARCH" == "ppc64le" ]]; then
      HTTPD_PORT="$(leaseLookup 'httpd-port')"
      EXTRA_ARGS="${EXTRA_ARGS} coreos.live.rootfs_url=http://${HOSTNAME}:${HTTPD_PORT}/${ROOTFS_NAME}"
    fi

    # Boot artifacts names/paths were exported above upon creation
    # Now create a VM based on the domain template
    echo "Exporting the variables needed to fill out the lease-based domain template"
    export DOMAIN_NAME="${NAME}"
    export DOMAIN_UUID
    export DOMAIN_VCPUS=${DOMAIN_VCPUS}
    export DOMAIN_MEMORY=${DOMAIN_MEMORY}
    export DOMAIN_MAC="${MAC_ADDRESS}"
    export QCOW_PATH="${LIBVIRT_IMAGE_PATH}"
    export QCOW_NAME="${DOMAIN_NAME}.qcow2"
    export NETWORK_NAME="${CLUSTER_NAME}"
    export EXTRA_ARGS
    envsubst < ${CLUSTER_PROFILE_DIR}/domain-install-template.xml > ${INSTALL_DIR}/"${NAME}-install.xml"
    envsubst < ${CLUSTER_PROFILE_DIR}/domain-template.xml > ${INSTALL_DIR}/"${NAME}.xml"

    echo "Prepared libvirt domain direct kernel boot into RAM for install xml:"
    cat ${INSTALL_DIR}/"${NAME}-install.xml"
    echo ""

    echo "Prepared libvirt domain booting to a written disk xml:"
    cat ${INSTALL_DIR}/"${NAME}.xml"
    echo ""

    # Create the volume used as the base for the image
    ${VIRSH} vol-delete ${QCOW_NAME} --pool ${POOL_NAME} || true
    ${VIRSH} vol-create-as \
     --name ${QCOW_NAME} \
     --pool ${POOL_NAME} \
     --format qcow2 \
     --capacity ${VOLUME_CAPACITY}

    # Start the domain
    ${VIRSH} define ${INSTALL_DIR}/"${NAME}-install.xml"
    ${VIRSH} start "${DOMAIN_NAME}"
    ${VIRSH} autostart "${DOMAIN_NAME}"

    # Redefine the domain so it reboots to disk instead of memory.
    # Rebooting to disk is done manually via restart_nodes below.
    ${VIRSH} define ${INSTALL_DIR}/"${NAME}.xml"

  else
    # Pre-create the disk volume
    clone_volume ${NAME}-volume

    echo "Creating ${NAME} vm..."
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
  fi
}

if [ "$INSTALLER_TYPE" == "default" ]; then
  # Create the bootstrap node.
  NODE="${LEASED_RESOURCE}-bootstrap"
  echo "Creating ${NODE} node..."
  MAC_ADDRESS=$(leaseLookup "bootstrap[0].mac")
  create_node ${NODE} ${MAC_ADDRESS} bootstrap
fi

# Create the control plane nodes.
for (( i=0; i<=${CONTROL_COUNT}-1; i++ )); do
  NODE="${LEASED_RESOURCE}-control-${i}"
  echo "Creating ${NODE} node..."
  MAC_ADDRESS=$(leaseLookup "control-plane[$i].mac")
  create_node ${NODE} ${MAC_ADDRESS} master
done

# Create the compute nodes.
for (( i=0; i<=${COMPUTE_COUNT}-1; i++ )); do
  NODE="${LEASED_RESOURCE}-compute-${i}"
  echo "Creating ${NODE} node..."
  MAC_ADDRESS=$(leaseLookup "compute[$i].mac")
  create_node ${NODE} ${MAC_ADDRESS} worker
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

if [ "$INSTALLER_TYPE" == "agent" ]; then
  restart_nodes &
  ${OCPINSTALL} --dir "${INSTALL_DIR}" agent wait-for bootstrap-complete --log-level=debug &
else
  ${OCPINSTALL} --dir "${INSTALL_DIR}" wait-for bootstrap-complete &
fi

wait "$!"

if [ "$INSTALLER_TYPE" == "default" ]; then
  # Sleep between destroy and undefine to allow for a slight destroy lag
  echo "Deleting ${LEASED_RESOURCE}-bootstrap node..."
  ${VIRSH} destroy "${LEASED_RESOURCE}-bootstrap"
  sleep 1s
  ${VIRSH} undefine "${LEASED_RESOURCE}-bootstrap"

  echo "Approving pending CSRs..."
  approve_csrs () {
    oc version --client
    while true; do
      if [[ ! -f ${INSTALL_DIR}/install-complete ]]; then
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
fi

# Add a small buffer before waiting for install completion
sleep 5m

set +x
echo "Completing UPI setup..."
if [ "$INSTALLER_TYPE" == "agent" ]; then
  ${OCPINSTALL} --dir="${INSTALL_DIR}" agent wait-for install-complete --log-level=debug 2>&1 | grep --line-buffered -v password &
else
  ${OCPINSTALL} --dir="${INSTALL_DIR}" wait-for install-complete 2>&1 | grep --line-buffered -v password &
fi
wait "$!"
save_credentials

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

# Patch etcd for allowing slower disks
if [[ "${ETCD_DISK_SPEED}" == "slow" ]]; then
  echo "Patching etcd cluster operator..."
  oc patch etcd cluster --type=merge --patch '{"spec":{"controlPlaneHardwareSpeed":"Slower"}}'
  for i in {1..30}; do
    ETCD_CO_AVAILABLE=$(oc get co etcd | grep etcd | awk '{print $3}')
    if [[ "${ETCD_CO_AVAILABLE}" == "True" ]]; then
      echo "Patched successfully!"
      break
    fi
    sleep 15
  done
  if [[ "${ETCD_CO_AVAILABLE}" != "True" ]]; then
    echo "Etcd patch failed..."
    exit 1
  fi
fi

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

touch ${INSTALL_DIR}/install-complete
