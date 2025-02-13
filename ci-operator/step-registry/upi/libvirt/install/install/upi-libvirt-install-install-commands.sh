#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${ARCH}" != "s390x" ]; then
  echo "upi-libvirt-install-install currently only supports s390x as node architecture"
  exit 1
fi

INSTALL_DIR="/tmp/installer"
mkdir -p $INSTALL_DIR
cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"

CLUSTER_DOMAIN="libvirt-s390x-amd64-0-0.ci"
LIBVIRT_DOMAIN_NAME_SUFFIX="libvirt-s390x-amd64-0-0-ci"

mkdir /tmp/bin

if [ -n "${OPENSHIFT_CLIENT_VERSION_OVERRIDE}" ]; then
  echo "Downloading openshift client ${OPENSHIFT_CLIENT_VERSION_OVERRIDE}"
  curl -o /tmp/openshift-client-linux.tar.gz -L "https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp/${OPENSHIFT_CLIENT_VERSION_OVERRIDE}/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/;')/openshift-client-linux.tar.gz"
  tar -xzvf /tmp/openshift-client-linux.tar.gz -C /tmp/bin oc && chmod u+x /tmp/bin/oc
fi

OCPINSTALL=openshift-install

export PATH=/tmp/bin:$PATH

function wait_for_domain_deletion() {
  wait_until=$(($(date +%s) + 600))

  echo "[$(date -Is)] waiting for domain $1 to be deleted, waiting until $(date -Is --date="@$wait_until")"

  until [ $((wait_until - $(date +%s)))  -le 0 ] || ! (mock-nss.sh virsh domid "$1" > /dev/null 2>&1); do
      sleep 5
  done
  if [ $((wait_until - $(date +%s))) -le 0 ]; then
    echo "Error, domain $1 was not deleted before timeout."
    return 1
  fi
  echo "Domain $1 was successfully deleted."
  return 0
}

function approve_csrs() {
  oc version --client
  while true; do
    if [[ ! -f /tmp/install-complete ]]; then
      # even if oc get csr fails continue
      echo "Checking for unapproved certs..."
      oc get csr | grep "Pending" || true
      oc get csr -ojson | yq-v4 -oy '.items[] | select(.status | length == 0) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

VOLUME_TEMPLATE_XML=$(cat <<EOF
<volume type='file'>
  <name></name>
  <capacity unit='bytes'></capacity>
  <target>
    <path></path>
    <format type='raw'/>
    <permissions>
      <mode>0644</mode>
      <owner>0</owner>
      <group>0</group>
    </permissions>
  </target>
</volume>
EOF
)

# Check if pool $1 contains file with name $2
function check_exists_in_pool {
  # check if file exists by checking if we can get vol-info without error
  mock-nss.sh virsh vol-info --pool "$1" "$2" > /dev/null 2>&1
}

# Upload a local file to a libvirt pool
# $1 is the pool to upload to
# $2 is the path to the local file to upload
# $3 is the path the file should be placed on the remote server
# does not overwrite file if it already exists
function upload_to_pool {
  local pool
  local filepath
  local filename
  local targetPath

  pool="$1"
  filepath="$2"
  filename="$(basename "$2")"
  targetPath="$3"

  if check_exists_in_pool "$pool" "$filename"; then
    echo "${filepath} already exists on pool ${pool}, skipping upload"
    return
  fi

  echo "Uploading ${filepath} to ${pool}"

  # to get correct rights, we create the volume via an XML file instead of
  # `virsh vol-create-as`
  echo "Creating volume from XML:"
  volume_xml_path=$(mktemp --tmpdir "$filename".xml.XXXXX)
  <<<"$VOLUME_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".volume.name=\"$filename\" | \
     .volume.capacity=\"$(stat -c %s "$filepath")\" | \
     .volume.target.path=\"$targetPath\"" \
    > "$volume_xml_path"
  cat "$volume_xml_path"

  mock-nss.sh virsh vol-create --pool "$pool" --file "$volume_xml_path"
  mock-nss.sh virsh vol-upload --pool "$pool" --vol "$filename" --file "$filepath"
}

# Deletes file $2 from pool $1, if it exists.
function delete_from_pool_if_exists {
  if check_exists_in_pool "$1" "$2"; then
    echo "Volume $2 exists in pool $1, deleting"
    mock-nss.sh virsh vol-delete --pool "$1" --vol "$2"
  fi
}

DOMAIN_TEMPLATE_XML=$(cat <<EOF
<domain type="kvm">
  <name></name>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://redhat.com/rhel/9.2"/>
    </libosinfo:libosinfo>
  </metadata>
  <memory></memory>
  <vcpu></vcpu>
  <os>
    <type arch="s390x" machine="s390-ccw-virtio">hvm</type>
  </os>
  <clock offset="utc"/>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file=""/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="bridge"/>
      <mac address=""/>
      <model type="virtio"/>
    </interface>
    <console type="pty">
      <target type="sclp"/>
    </console>
    <channel type="unix">
      <source mode="bind"/>
      <target type="virtio" name="org.qemu.guest_agent.0"/>
    </channel>
    <memballoon model="virtio"/>
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF
)

HTTPD_BASE_URL="http://172.16.41.20:8080/"


echo "Creating manifests."
$OCPINSTALL create manifests --dir "${INSTALL_DIR}"

echo "Setting mastersSchedulable to false in manifests/cluster-scheduler-02-config.yml"
yq-v4 -i '.spec.mastersSchedulable = false' "${INSTALL_DIR}"/manifests/cluster-scheduler-02-config.yml
cat "${INSTALL_DIR}"/manifests/cluster-scheduler-02-config.yml

cp "${SHARED_DIR}/manifest_etcd-on-ramfs-mc.yml" "${INSTALL_DIR}/manifests/manifest_etcd-on-ramfs-mc.yml"

echo "Creating and uploading ignition files."

export LIBVIRT_DEFAULT_URI="qemu+tcp://lnxocp10:16509/system"
$OCPINSTALL create ignition-configs --dir "${INSTALL_DIR}"

delete_from_pool_if_exists httpd "bootstrap.ign"
upload_to_pool httpd "${INSTALL_DIR}/bootstrap.ign" "/var/www/html/bootstrap.ign"

delete_from_pool_if_exists httpd "master.ign"
upload_to_pool httpd "${INSTALL_DIR}/master.ign" "/var/www/html/master.ign"

delete_from_pool_if_exists httpd "worker.ign"
upload_to_pool httpd "${INSTALL_DIR}/worker.ign" "/var/www/html/worker.ign"

# Prepare boot artifacts:
#
# We only upload the rootfs, which is the largest required image,
# to the httpd before calling virt-install and only once per RHCOS version.
#
# virt-install then downloads the initramfs and kernel and uploads them
# as temporary boot artifacts via libvirt for each machine that is booted.
KERNEL_URL=$($OCPINSTALL coreos print-stream-json | yq-v4 -oy ".architectures.$ARCH.artifacts.metal.formats.pxe.kernel.location")
INITRAMFS_URL=$($OCPINSTALL coreos print-stream-json | yq-v4 -oy ".architectures.$ARCH.artifacts.metal.formats.pxe.initramfs.location")
ROOTFS_URL=$($OCPINSTALL coreos print-stream-json | yq-v4 -oy ".architectures.$ARCH.artifacts.metal.formats.pxe.rootfs.location")
echo "Found kernel=${KERNEL_URL}, initrd=${INITRAMFS_URL}, and rootfs=${ROOTFS_URL}"

KERNEL_FILENAME=$(basename "$KERNEL_URL")
INITRAMFS_FILENAME=$(basename "$INITRAMFS_URL")
ROOTFS_FILENAME=$(basename "$ROOTFS_URL")

if [[ $(dirname "$KERNEL_URL") != $(dirname "$INITRAMFS_URL") ]]; then
  echo "Error, expected kernel and initramfs to have same base url, found:"
  echo "  $(dirname "$KERNEL_URL")"
  echo "  $(dirname "$INITRAMFS_URL")"
  echo "Aborting"
  exit 1
fi

# only download and transfer rootfs if it doesn't already exist on httpd
if check_exists_in_pool httpd "$ROOTFS_FILENAME"; then
  echo "rootfs ($ROOTFS_FILENAME) already exists on httpd, skipping transfer"
else
  echo "Downloading rootfs from $ROOTFS_URL"
  curl -L "$ROOTFS_URL" -o "/tmp/$ROOTFS_FILENAME"
  upload_to_pool httpd "/tmp/$ROOTFS_FILENAME" "/var/www/html/$ROOTFS_FILENAME"
fi

HOST_BOOT_ARTIFACT_BASE=/var/lib/libvirt/boot/
HOST_PATH_KERNEL=${HOST_BOOT_ARTIFACT_BASE}${KERNEL_FILENAME}
HOST_PATH_INITRAMFS=${HOST_BOOT_ARTIFACT_BASE}${INITRAMFS_FILENAME}


if check_exists_in_pool boot-scratch "$KERNEL_FILENAME"; then
  echo "kernel ($KERNEL_FILENAME) already exists in boot-scratch, skipping transfer"
else
  echo "Downloading kernel from $KERNEL_URL"
  curl -o "/tmp/$KERNEL_FILENAME" -L "$KERNEL_URL"
  upload_to_pool boot-scratch "/tmp/$KERNEL_FILENAME" "$HOST_PATH_KERNEL"
fi

if check_exists_in_pool boot-scratch "$INITRAMFS_FILENAME"; then
  echo "initramfs ($INITRAMFS_FILENAME) already exists in boot-scratch, skipping transfer"
else
  echo "Downloading initramfs from $INITRAMFS_URL"
  curl -o "/tmp/$INITRAMFS_FILENAME" -L "$INITRAMFS_URL"
  upload_to_pool boot-scratch "/tmp/$INITRAMFS_FILENAME" "$HOST_PATH_INITRAMFS"
fi



# Boot the cluster nodes

# Define nodes to create
NODE_DEFINITIONS=$(cat <<EOF
- name: bootstrap-$LIBVIRT_DOMAIN_NAME_SUFFIX
  mac: 52:54:AC:10:29:16
  extra-args:
    - ip=172.16.41.22::172.16.41.1:255.255.255.0:bootstrap.$CLUSTER_DOMAIN:enc1:none:1500
    - nameserver=172.16.41.20
    - coreos.inst.ignition_url=$HTTPD_BASE_URL/bootstrap.ign
- name: master-0-$LIBVIRT_DOMAIN_NAME_SUFFIX
  mac: 52:54:AC:10:29:17
  extra-args:
    - ip=172.16.41.23::172.16.41.1:255.255.255.0:master-0.$CLUSTER_DOMAIN:enc1:none:1500
    - nameserver=172.16.41.20
    - coreos.inst.ignition_url=$HTTPD_BASE_URL/master.ign
- name: master-1-$LIBVIRT_DOMAIN_NAME_SUFFIX
  mac: 52:54:AC:10:29:18
  extra-args:
    - ip=172.16.41.24::172.16.41.1:255.255.255.0:master-1.$CLUSTER_DOMAIN:enc1:none:1500
    - nameserver=172.16.41.20
    - coreos.inst.ignition_url=$HTTPD_BASE_URL/master.ign
- name: master-2-$LIBVIRT_DOMAIN_NAME_SUFFIX
  mac: 52:54:AC:10:29:19
  extra-args:
    - ip=172.16.41.25::172.16.41.1:255.255.255.0:master-2.$CLUSTER_DOMAIN:enc1:none:1500
    - nameserver=172.16.41.20
    - coreos.inst.ignition_url=$HTTPD_BASE_URL/master.ign
- name: worker-0-$LIBVIRT_DOMAIN_NAME_SUFFIX
  mac: 52:54:AC:10:29:1A
  extra-args:
    - ip=172.16.41.26::172.16.41.1:255.255.255.0:worker-0.$CLUSTER_DOMAIN:enc1:none:1500
    - nameserver=172.16.41.20
    - coreos.inst.ignition_url=$HTTPD_BASE_URL/worker.ign
- name: worker-1-$LIBVIRT_DOMAIN_NAME_SUFFIX
  mac: 52:54:AC:10:29:1B
  extra-args:
    - ip=172.16.41.27::172.16.41.1:255.255.255.0:worker-1.$CLUSTER_DOMAIN:enc1:none:1500
    - nameserver=172.16.41.20
    - coreos.inst.ignition_url=$HTTPD_BASE_URL/worker.ign
EOF
)

# iterate over nodes and boot each of them
for c in $(seq "$(<<<"$NODE_DEFINITIONS" yq-v4 'length')"); do
  node_definition=$(<<<"$NODE_DEFINITIONS" yq-v4 ".[$((c-1))]")
  node_name=$(<<<"$node_definition" yq-v4 .name)
  node_mac=$(<<<"$node_definition" yq-v4 .mac)

  domain_cmdline="rd.neednet=1 coreos.inst.install_dev=/dev/vda coreos.live.rootfs_url=$HTTPD_BASE_URL/$ROOTFS_FILENAME "
  domain_cmdline+=$(<<<"$node_definition" yq-v4 '.extra-args | join(" ")')

  echo "Creating .qcow2 image for ${node_name}"
  delete_from_pool_if_exists images "${node_name}".qcow2
  mock-nss.sh virsh vol-create-as \
    --pool images \
    --name "${node_name}".qcow2 \
    --capacity ${DOMAIN_DISK_SIZE} \
    --format qcow2
  domain_qcow2_image_host_path=/var/lib/libvirt/images/${node_name}.qcow2

  echo "Preparing XML for ${node_name}"
  domain_xml_path=$(mktemp --tmpdir domain-"${node_name}".xml.XXXXX)
  <<<"$DOMAIN_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".domain.name=\"${node_name}\" |
    .domain.memory=\"${DOMAIN_MEMORY}\" |
    .domain.vcpu=\"${DOMAIN_VCPUS}\" |
    .domain.os.kernel=\"${HOST_PATH_KERNEL}\" |
    .domain.os.initrd=\"${HOST_PATH_INITRAMFS}\" |
    .domain.os.cmdline=\"${domain_cmdline}\" |
    .domain.devices.disk.source.+@file=\"${domain_qcow2_image_host_path}\" |
    .domain.devices.interface.mac.+@address=\"${node_mac}\" |
    .domain.on_reboot=\"destroy\"" \
    > "$domain_xml_path"


  echo "Creating domain from xml:"
  cat "$domain_xml_path"
  mock-nss.sh virsh create "$domain_xml_path" --validate
done

for c in $(seq "$(<<<"$NODE_DEFINITIONS" yq-v4 'length')"); do
  node_definition=$(<<<"$NODE_DEFINITIONS" yq-v4 ".[$((c-1))]")
  node_name=$(<<<"$node_definition" yq-v4 .name)
  node_mac=$(<<<"$node_definition" yq-v4 .mac)

  domain_cmdline="rd.neednet=1 coreos.inst.install_dev=/dev/vda coreos.live.rootfs_url=$HTTPD_BASE_URL/$ROOTFS_FILENAME "
  domain_cmdline+=$(<<<"$node_definition" yq-v4 '.extra-args | join(" ")')

  domain_qcow2_image_host_path=/var/lib/libvirt/images/${node_name}.qcow2

  wait_for_domain_deletion "$node_name"

  echo "Domain was deleted, creating new domain ${node_name} that boots from disk"
  domain_xml_path=$(mktemp --tmpdir domain-"${node_name}".xml.XXXXX)
  <<<"$DOMAIN_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".domain.name=\"${node_name}\" |
    .domain.memory=\"${DOMAIN_MEMORY}\" |
    .domain.vcpu=\"${DOMAIN_VCPUS}\" |
    .domain.os.boot.+@dev=\"hd\" |
    .domain.devices.disk.source.+@file=\"${domain_qcow2_image_host_path}\" |
    .domain.devices.interface.mac.+@address=\"${node_mac}\"" \
    > "$domain_xml_path"

  echo "Creating domain from xml:"
  cat "$domain_xml_path"
  mock-nss.sh virsh define "$domain_xml_path" --validate
  mock-nss.sh virsh start "$node_name"
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

$OCPINSTALL --dir "${INSTALL_DIR}" wait-for bootstrap-complete &
# TODO: collect logs in case of failure
wait "$!"

echo "Approving pending CSRs"
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig
approve_csrs &

sleep 15m

set +x
echo "Completing UPI setup"
$OCPINSTALL --dir="${INSTALL_DIR}" wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

oc config refresh-ca-bundle

echo "Saving authentication files for next steps."
cp "${INSTALL_DIR}/metadata.json" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/"
cp "${INSTALL_DIR}/auth/kubeadmin-password" "${SHARED_DIR}/"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' "${INSTALL_DIR}"/.openshift_install.log
cp "${INSTALL_DIR}"/.openshift_install.log "${SHARED_DIR}"/.openshift_install.log

touch /tmp/install-complete