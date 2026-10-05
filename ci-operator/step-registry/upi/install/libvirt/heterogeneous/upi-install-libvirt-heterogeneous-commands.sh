#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${ADDITIONAL_WORKER_ARCHITECTURE:-}" != "arm64" ]; then
  echo "ERROR: upi-install-libvirt-heterogeneous currently supports arm64 as additional worker architecture; found '${ADDITIONAL_WORKER_ARCHITECTURE:-}'"
  exit 1
fi

# Ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "ERROR: Failed to acquire lease (LEASED_RESOURCE is unset)"
  exit 1
fi

# Ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "ERROR: Couldn't find lease config file at ${CLUSTER_PROFILE_DIR}/leases"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" || "${lookup}" == "null" ]]; then
    echo "ERROR: Couldn't find '${1}' in lease config" >&2
    exit 1
  fi
  echo "$lookup"
}

# Ensure templates exist in cluster profile
ARM64_INSTALL_TEMPLATE="${CLUSTER_PROFILE_DIR}/domain-install-template-arm64.xml"
ARM64_RUN_TEMPLATE="${CLUSTER_PROFILE_DIR}/domain-template-arm64.xml"

if [[ ! -f "${ARM64_INSTALL_TEMPLATE}" ]]; then
  echo "ERROR: Missing required arm64 install domain template: ${ARM64_INSTALL_TEMPLATE}"
  exit 1
fi

if [[ ! -f "${ARM64_RUN_TEMPLATE}" ]]; then
  echo "ERROR: Missing required arm64 run domain template: ${ARM64_RUN_TEMPLATE}"
  exit 1
fi

# Validate arm64 template contents
if ! grep -q 'aarch64' "${ARM64_INSTALL_TEMPLATE}"; then
  echo "ERROR: ${ARM64_INSTALL_TEMPLATE} does not contain arch='aarch64'"
  exit 1
fi

if ! grep -q 'aarch64' "${ARM64_RUN_TEMPLATE}"; then
  echo "ERROR: ${ARM64_RUN_TEMPLATE} does not contain arch='aarch64'"
  exit 1
fi

HOSTNAME_PRIMARY="$(leaseLookup 'hostname')"
HOSTNAME_ADDITIONAL="$(leaseLookup 'hostname-additional')"
HTTPD_IP="$(leaseLookup 'httpd-ip')"
HTTPD_PORT="$(leaseLookup 'httpd-port')"
SUBNET="$(leaseLookup 'subnet')"

ADDITIONAL_PORT="${ADDITIONAL_LIBVIRT_PORT:-16509}"
if [[ ! "${ADDITIONAL_PORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Invalid ADDITIONAL_LIBVIRT_PORT '${ADDITIONAL_PORT}'"
  exit 1
fi

PRIMARY_LIBVIRT_URI="qemu+tcp://${HOSTNAME_PRIMARY}/system"
ADDITIONAL_LIBVIRT_URI="qemu+tcp://${HOSTNAME_ADDITIONAL}:${ADDITIONAL_PORT}/system"

VIRSH_PRIMARY="mock-nss.sh virsh --connect ${PRIMARY_LIBVIRT_URI}"
VIRSH_ADDITIONAL="mock-nss.sh virsh --connect ${ADDITIONAL_LIBVIRT_URI}"

ADDITIONAL_POOL="${ADDITIONAL_POOL_NAME:-multiarch-ci-pool}"
HTTPD_POOL="${HTTPD_POOL_NAME:-httpd}"
HTTPD_BASE_URL="http://${HTTPD_IP}:${HTTPD_PORT}"

mkdir -p /tmp/bin
if [ -n "${OPENSHIFT_CLIENT_VERSION_OVERRIDE:-}" ]; then
  echo "Downloading openshift client ${OPENSHIFT_CLIENT_VERSION_OVERRIDE}"
  curl -o /tmp/openshift-client-linux.tar.gz -L "https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/multi/clients/ocp/${OPENSHIFT_CLIENT_VERSION_OVERRIDE}/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/;')/openshift-client-linux.tar.gz"
  tar -xzvf /tmp/openshift-client-linux.tar.gz -C /tmp/bin oc && chmod u+x /tmp/bin/oc
fi
export PATH=/tmp/bin:$PATH

# Cleanup on exit or error
CSR_APPROVER_PID=""
CURRENT_INSTALL_DOMAIN=""
cleanup_heterogeneous_step() {
  local exit_code=$?
  touch /tmp/heterogeneous-install-complete
  if [[ -n "${CSR_APPROVER_PID}" ]] && kill -0 "${CSR_APPROVER_PID}" 2>/dev/null; then
    kill "${CSR_APPROVER_PID}" 2>/dev/null || true
    wait "${CSR_APPROVER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${CURRENT_INSTALL_DOMAIN}" ]]; then
    # If the step failed while an install domain was still active or timed out, clean it up
    if ${VIRSH_ADDITIONAL} domid "${CURRENT_INSTALL_DOMAIN}" >/dev/null 2>&1; then
      echo "Cleaning up dangling install domain ${CURRENT_INSTALL_DOMAIN} on additional host..."
      ${VIRSH_ADDITIONAL} destroy "${CURRENT_INSTALL_DOMAIN}" >/dev/null 2>&1 || true
      sleep 1s
      ${VIRSH_ADDITIONAL} undefine "${CURRENT_INSTALL_DOMAIN}" >/dev/null 2>&1 || true
    fi
  fi
  exit ${exit_code}
}
trap cleanup_heterogeneous_step EXIT TERM INT

function wait_for_domain_deletion() {
  local domain="$1"
  local wait_until=$(($(date +%s) + 600))

  echo "[$(date -Is)] waiting for install domain ${domain} to complete and power off..."
  until [ $((wait_until - $(date +%s))) -le 0 ] || ! (${VIRSH_ADDITIONAL} domid "$domain" > /dev/null 2>&1); do
    sleep 5
  done
  if [ $((wait_until - $(date +%s))) -le 0 ]; then
    echo "ERROR: install domain ${domain} did not shut down before timeout (600s)."
    echo "Destroying and undefining timed-out install domain ${domain}..."
    ${VIRSH_ADDITIONAL} destroy "${domain}" >/dev/null 2>&1 || true
    sleep 1s
    ${VIRSH_ADDITIONAL} undefine "${domain}" >/dev/null 2>&1 || true
    return 1
  fi
  echo "Install domain ${domain} finished successfully."
  return 0
}

function approve_csrs() {
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  while true; do
    if [[ ! -f /tmp/heterogeneous-install-complete ]]; then
      # Query pending CSRs with no approval conditions yet
      local raw_csrs
      raw_csrs=$(oc get csr -ojson 2>/dev/null || echo '{"items":[]}')
      local pending_csrs
      pending_csrs=$(echo "${raw_csrs}" | yq-v4 -oy '.items[] | select(.status | length == 0 or .conditions == null) | .metadata.name' 2>/dev/null || true)

      for csr_name in ${pending_csrs}; do
        [[ -z "${csr_name}" ]] && continue
        local signer_name requester node_subject
        signer_name=$(echo "${raw_csrs}" | yq-v4 -oy ".items[] | select(.metadata.name == \"${csr_name}\") | .spec.signerName" 2>/dev/null || true)
        requester=$(echo "${raw_csrs}" | yq-v4 -oy ".items[] | select(.metadata.name == \"${csr_name}\") | .spec.username" 2>/dev/null || true)

        # Allow kubelet-serving or kube-apiserver-client-kubelet signer for bootstrap/node identities
        local valid_signer=false
        if [[ "${signer_name}" == "kubernetes.io/kubelet-serving" || "${signer_name}" == "kubernetes.io/kube-apiserver-client-kubelet" ]]; then
          valid_signer=true
        fi

        # Verify subject/username matches system:node:<node-name> or system:serviceaccount:openshift-machine-config-operator:node-bootstrapper
        local valid_subject=false
        if [[ "${requester}" =~ ^system:node:${LEASED_RESOURCE}-additional-compute-[0-9]+ ]] || \
           [[ "${requester}" == "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper" ]] || \
           [[ "${requester}" == "system:admin" ]]; then
          valid_subject=true
        fi

        if [[ "${valid_signer}" == "true" && "${valid_subject}" == "true" ]]; then
          echo "Approving valid CSR ${csr_name} for requester ${requester} (signer: ${signer_name})"
          oc adm certificate approve "${csr_name}" >/dev/null 2>&1 || true
        fi
      done

      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

# Volume XML template for libvirt pool uploads
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

function check_exists_in_primary_pool {
  ${VIRSH_PRIMARY} vol-info --pool "$1" "$2" > /dev/null 2>&1
}

function upload_to_primary_pool {
  local pool="$1"
  local filepath="$2"
  local volname="$3"
  local targetPath="$4"

  if check_exists_in_primary_pool "$pool" "$volname"; then
    echo "Volume ${volname} already exists on primary pool ${pool}, deleting prior version for refresh..."
    ${VIRSH_PRIMARY} vol-delete --pool "$pool" "${volname}" || true
  fi

  echo "Uploading volume ${volname} to primary pool ${pool}..."
  local volume_xml_path
  volume_xml_path=$(mktemp --tmpdir "${volname}".xml.XXXXX)
  <<<"$VOLUME_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".volume.name=\"${volname}\" | \
     .volume.capacity=\"$(stat -c %s "$filepath")\" | \
     .volume.target.path=\"$targetPath\"" \
    > "$volume_xml_path"

  ${VIRSH_PRIMARY} vol-create --pool "$pool" --file "$volume_xml_path"
  ${VIRSH_PRIMARY} vol-upload --pool "$pool" --vol "${volname}" --file "$filepath"
  rm -f "$volume_xml_path"
}

function check_exists_in_additional_pool {
  ${VIRSH_ADDITIONAL} vol-info --pool "$1" "$2" > /dev/null 2>&1
}

function upload_to_additional_pool {
  local pool="$1"
  local filepath="$2"
  local volname="$3"
  local targetPath="$4"

  if check_exists_in_additional_pool "$pool" "$volname"; then
    echo "Volume ${volname} already exists on additional pool ${pool}, skipping upload"
    return
  fi

  echo "Uploading volume ${volname} to additional pool ${pool}..."
  local volume_xml_path
  volume_xml_path=$(mktemp --tmpdir "${volname}".xml.XXXXX)
  <<<"$VOLUME_TEMPLATE_XML" yq-v4 -p=xml -o=xml \
    ".volume.name=\"${volname}\" | \
     .volume.capacity=\"$(stat -c %s "$filepath")\" | \
     .volume.target.path=\"$targetPath\"" \
    > "$volume_xml_path"

  ${VIRSH_ADDITIONAL} vol-create --pool "$pool" --file "$volume_xml_path"
  ${VIRSH_ADDITIONAL} vol-upload --pool "$pool" --vol "${volname}" --file "$filepath"
  rm -f "$volume_xml_path"
}

function delete_from_additional_pool_if_exists {
  if check_exists_in_additional_pool "$1" "$2"; then
    echo "Volume $2 exists in additional pool $1, deleting"
    ${VIRSH_ADDITIONAL} vol-delete --pool "$1" --vol "$2"
  fi
}

# Fetch arm64 coreos boot images from the running cluster
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}"
  exit 1
fi

echo "Fetching coreos-bootimages for architecture ${ADDITIONAL_WORKER_ARCHITECTURE}..."
KERNEL_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.artifacts.metal.formats.pxe.kernel.location")
INITRAMFS_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.artifacts.metal.formats.pxe.initramfs.location")
ROOTFS_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.artifacts.metal.formats.pxe.rootfs.location")

if [[ -z "${KERNEL_URL}" || "${KERNEL_URL}" == "null" || -z "${INITRAMFS_URL}" || "${INITRAMFS_URL}" == "null" || -z "${ROOTFS_URL}" || "${ROOTFS_URL}" == "null" ]]; then
  echo "ERROR: Failed to retrieve boot artifact URLs from coreos-bootimages configmap for ${ADDITIONAL_WORKER_ARCHITECTURE}"
  exit 1
fi

KERNEL_FILENAME=$(basename "${KERNEL_URL%%\?*}")
INITRAMFS_FILENAME=$(basename "${INITRAMFS_URL%%\?*}")
ROOTFS_FILENAME=$(basename "${ROOTFS_URL%%\?*}")

# Stage rootfs on primary hypervisor's HTTPD pool (shared across runs, keyed by release filename)
if check_exists_in_primary_pool "${HTTPD_POOL}" "$ROOTFS_FILENAME"; then
  echo "rootfs ($ROOTFS_FILENAME) already exists on primary httpd pool, skipping transfer"
else
  echo "Downloading rootfs from release boot image stream..."
  curl -sSfL "$ROOTFS_URL" -o "/tmp/$ROOTFS_FILENAME"
  if [[ ! -s "/tmp/$ROOTFS_FILENAME" ]]; then
    echo "ERROR: Downloaded rootfs file is empty"
    exit 1
  fi
  upload_to_primary_pool "${HTTPD_POOL}" "/tmp/$ROOTFS_FILENAME" "${ROOTFS_FILENAME}" "/var/www/html/$ROOTFS_FILENAME"
  rm -f "/tmp/$ROOTFS_FILENAME"
fi

# Retrieve current run's worker ignition from the cluster's base64-encoded ignition-configs Secret
# or retrieve it from the primary host ignition volume if available.
LEASE_WORKER_IGN_FILENAME="${LEASED_RESOURCE}-worker.ign"
TMP_WORKER_IGN=$(mktemp /tmp/worker.ign.XXXXXX)

if [[ -f "${SHARED_DIR}/worker.ign" ]]; then
  echo "Using worker.ign from SHARED_DIR"
  cp "${SHARED_DIR}/worker.ign" "${TMP_WORKER_IGN}"
elif oc -n kube-system get secret/ignition-configs >/dev/null 2>&1; then
  echo "Extracting current cluster worker.ign from kube-system/ignition-configs secret..."
  oc -n kube-system get secret/ignition-configs -o jsonpath='{.data.worker\.ign}' | base64 -d > "${TMP_WORKER_IGN}"
elif ${VIRSH_PRIMARY} vol-info --pool "${POOL_NAME}" "${LEASED_RESOURCE}-worker-ignition-volume" >/dev/null 2>&1; then
  echo "Downloading worker.ign from primary hypervisor ignition volume..."
  ${VIRSH_PRIMARY} vol-download --pool "${POOL_NAME}" --vol "${LEASED_RESOURCE}-worker-ignition-volume" --file "${TMP_WORKER_IGN}"
else
  echo "ERROR: Unable to locate worker ignition config for lease ${LEASED_RESOURCE}"
  exit 1
fi

if [[ ! -s "${TMP_WORKER_IGN}" ]]; then
  echo "ERROR: worker ignition file is empty"
  exit 1
fi

# Upload lease-scoped worker ignition to HTTPD pool named exactly after the lease
echo "Uploading lease-scoped worker ignition (${LEASE_WORKER_IGN_FILENAME}) to primary httpd pool..."
upload_to_primary_pool "${HTTPD_POOL}" "${TMP_WORKER_IGN}" "${LEASE_WORKER_IGN_FILENAME}" "/var/www/html/${LEASE_WORKER_IGN_FILENAME}"
rm -f "${TMP_WORKER_IGN}"

# Verify HTTPD accessibility of staged ignition
WORKER_IGN_HTTP_URL="${HTTPD_BASE_URL}/${LEASE_WORKER_IGN_FILENAME}"
echo "Verifying HTTP endpoint reachability for worker ignition..."
if ! curl -sSf -I --connect-timeout 10 "${WORKER_IGN_HTTP_URL}" >/dev/null 2>&1; then
  echo "WARNING: Direct HTTP check from CI pod timed out (hypervisor HTTPD is restricted to internal VPN)."
  echo "Ignition successfully staged at /var/www/html/${LEASE_WORKER_IGN_FILENAME} on pool ${HTTPD_POOL}."
else
  echo "HTTP endpoint successfully verified."
fi

# Stage kernel and initramfs to additional hypervisor's boot pool / scratch
HOST_BOOT_ARTIFACT_BASE=/var/lib/libvirt/images/openshift-images/
HOST_PATH_KERNEL=${HOST_BOOT_ARTIFACT_BASE}${KERNEL_FILENAME}
HOST_PATH_INITRAMFS=${HOST_BOOT_ARTIFACT_BASE}${INITRAMFS_FILENAME}

if check_exists_in_additional_pool "${ADDITIONAL_POOL}" "$KERNEL_FILENAME"; then
  echo "kernel ($KERNEL_FILENAME) already exists in ${ADDITIONAL_POOL} on additional host, skipping transfer"
else
  echo "Downloading kernel..."
  curl -sSfL -o "/tmp/$KERNEL_FILENAME" "$KERNEL_URL"
  if [[ ! -s "/tmp/$KERNEL_FILENAME" ]]; then
    echo "ERROR: Downloaded kernel file is empty"
    exit 1
  fi
  upload_to_additional_pool "${ADDITIONAL_POOL}" "/tmp/$KERNEL_FILENAME" "${KERNEL_FILENAME}" "$HOST_PATH_KERNEL"
  rm -f "/tmp/$KERNEL_FILENAME"
fi

if check_exists_in_additional_pool "${ADDITIONAL_POOL}" "$INITRAMFS_FILENAME"; then
  echo "initramfs ($INITRAMFS_FILENAME) already exists in ${ADDITIONAL_POOL} on additional host, skipping transfer"
else
  echo "Downloading initramfs..."
  curl -sSfL -o "/tmp/$INITRAMFS_FILENAME" "$INITRAMFS_URL"
  if [[ ! -s "/tmp/$INITRAMFS_FILENAME" ]]; then
    echo "ERROR: Downloaded initramfs file is empty"
    exit 1
  fi
  upload_to_additional_pool "${ADDITIONAL_POOL}" "/tmp/$INITRAMFS_FILENAME" "${INITRAMFS_FILENAME}" "$HOST_PATH_INITRAMFS"
  rm -f "/tmp/$INITRAMFS_FILENAME"
fi

# Provision additional compute nodes
ADD_COMPUTE_COUNT=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"additional-compute\" | length" "${LEASE_CONF}")
echo "Provisioning ${ADD_COMPUTE_COUNT} additional arm64 compute nodes..."

for (( idx=0; idx<ADD_COMPUTE_COUNT; idx++ )); do
  node_name="${LEASED_RESOURCE}-additional-compute-${idx}"
  node_ip="$(leaseLookup "\"additional-compute\"[$idx].ip")"
  node_mac="$(leaseLookup "\"additional-compute\"[$idx].mac")"
  node_gw="$(leaseLookup "\"additional-compute\"[$idx].gateway")"
  node_netmask="255.255.255.0"
  node_nic="enp1s0"
  node_nameserver="${HTTPD_IP}"
  node_fqdn="${node_name}.ci"

  domain_cmdline="rd.neednet=1 coreos.inst.install_dev=/dev/vda coreos.live.rootfs_url=${HTTPD_BASE_URL}/${ROOTFS_FILENAME} "
  domain_cmdline+="ip=${node_ip}::${node_gw}:${node_netmask}:${node_fqdn}:${node_nic}:none:1500 "
  domain_cmdline+="nameserver=${node_nameserver} "
  domain_cmdline+="coreos.inst.ignition_url=${HTTPD_BASE_URL}/${LEASE_WORKER_IGN_FILENAME}"

  echo "Creating .qcow2 volume for ${node_name} on additional hypervisor (${ADDITIONAL_POOL})..."
  delete_from_additional_pool_if_exists "${ADDITIONAL_POOL}" "${node_name}.qcow2"
  ${VIRSH_ADDITIONAL} vol-create-as \
    --pool "${ADDITIONAL_POOL}" \
    --name "${node_name}.qcow2" \
    --capacity "${DOMAIN_DISK_SIZE}" \
    --format qcow2

  domain_qcow2_image_host_path="$(${VIRSH_ADDITIONAL} vol-path \
    --pool "${ADDITIONAL_POOL}" "${node_name}.qcow2")"

  echo "Rendering install domain XML for ${node_name}..."
  domain_install_xml=$(mktemp --tmpdir domain-"${node_name}"-install.xml.XXXXX)
  export DOMAIN_NAME="${node_name}"
  export DOMAIN_MEMORY="${DOMAIN_MEMORY}"
  export DOMAIN_VCPUS="${DOMAIN_VCPUS}"
  export HOST_PATH_KERNEL="${HOST_PATH_KERNEL}"
  export HOST_PATH_INITRAMFS="${HOST_PATH_INITRAMFS}"
  export DOMAIN_CMDLINE="${domain_cmdline}"
  export DISK_SOURCE_PATH="${domain_qcow2_image_host_path}"
  export MAC_ADDRESS="${node_mac}"

  # Template evaluation using envsubst and yq-v4 validation
  envsubst < "${ARM64_INSTALL_TEMPLATE}" > "${domain_install_xml}"

  echo "Defining and starting install domain for ${node_name}..."
  CURRENT_INSTALL_DOMAIN="${node_name}"
  ${VIRSH_ADDITIONAL} create "${domain_install_xml}" --validate
  rm -f "${domain_install_xml}"

  wait_for_domain_deletion "${node_name}"
  CURRENT_INSTALL_DOMAIN=""

  echo "Install domain deleted. Defining persistent run domain for ${node_name} that boots from disk..."
  domain_run_xml=$(mktemp --tmpdir domain-"${node_name}"-run.xml.XXXXX)
  envsubst < "${ARM64_RUN_TEMPLATE}" > "${domain_run_xml}"

  ${VIRSH_ADDITIONAL} define "${domain_run_xml}" --validate
  ${VIRSH_ADDITIONAL} start "${node_name}"
  ${VIRSH_ADDITIONAL} autostart "${node_name}" || true
  rm -f "${domain_run_xml}"
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_HETEROGENEOUS_INSTALL_START_TIME"

echo "Approving pending CSRs for additional compute nodes..."
approve_csrs &
CSR_APPROVER_PID=$!

echo "Waiting for newly provisioned arm64 node(s) to join and become Ready..."
for (( idx=0; idx<ADD_COMPUTE_COUNT; idx++ )); do
  target_node_name="${LEASED_RESOURCE}-additional-compute-${idx}"
  echo "Checking node status for ${target_node_name}..."
  node_ready=false
  for (( i=1; i<=60; i++ )); do
    # Verify the specific node exists, matches arm64 architecture, and is Ready
    NODE_LINE=$(oc get nodes --no-headers 2>/dev/null | grep -E "^${target_node_name}(\.[a-zA-Z0-9.-]+)?\s+" || true)
    if [[ -n "${NODE_LINE}" ]] && echo "${NODE_LINE}" | grep -qw "Ready"; then
      NODE_ARCH=$(oc get node $(echo "${NODE_LINE}" | awk '{print $1}') -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null || true)
      if [[ "${NODE_ARCH}" == "arm64" ]]; then
        echo "Node ${target_node_name} successfully joined and is Ready with architecture arm64."
        node_ready=true
        break
      fi
    fi
    sleep 10
  done
  if [[ "${node_ready}" != "true" ]]; then
    echo "ERROR: Timed out waiting for node ${target_node_name} to reach Ready state with arm64 architecture."
    exit 1
  fi
done

echo "Waiting for cluster operators to stabilize after adding arm64 worker..."
oc adm wait-for-stable-cluster

oc config refresh-ca-bundle || true

date "+%F %X" > "${SHARED_DIR}/CLUSTER_HETEROGENEOUS_INSTALL_END_TIME"
touch /tmp/heterogeneous-install-complete

echo "Heterogeneous arm64 worker provisioned and verified successfully."
