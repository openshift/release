#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

require_commands() {
  local cmd
  local -a missing=()

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf 'ERROR: missing dependencies: %s\n' "${missing[*]}" >&2
    printf 'Fix the step image before retrying.\n' >&2
    exit 1
  fi
}

require_commands \
  yq-v4 oc mock-nss.sh virsh curl envsubst \
  awk grep sed tar gzip base64 basename stat mktemp \
  date mkdir rm cp touch sleep chmod uname cat tr mv

case "${ADDITIONAL_WORKER_ARCHITECTURE:-}" in
  arm64|aarch64)
    STREAM_ARCH="aarch64"
    EXPECTED_NODE_ARCH="arm64"
    TEMPLATE_ARCH="arm64"
    ;;
  amd64|x86_64)
    STREAM_ARCH="x86_64"
    EXPECTED_NODE_ARCH="amd64"
    TEMPLATE_ARCH="amd64"
    ;;
  *)
    echo "ERROR: upi-install-libvirt-heterogeneous currently supports arm64 or amd64 as additional worker architecture; found '${ADDITIONAL_WORKER_ARCHITECTURE:-}'"
    exit 1
    ;;
esac

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
INSTALL_TEMPLATE=""
RUN_TEMPLATE=""

for candidate in \
  "${CLUSTER_PROFILE_DIR}/domain-install-template-${TEMPLATE_ARCH}.xml" \
  "${CLUSTER_PROFILE_DIR}/domain-install-template-${STREAM_ARCH}.xml" \
  "${CLUSTER_PROFILE_DIR}/domain-install-template.xml"; do
  if [[ -f "${candidate}" ]]; then
    INSTALL_TEMPLATE="${candidate}"
    break
  fi
done

for candidate in \
  "${CLUSTER_PROFILE_DIR}/domain-template-${TEMPLATE_ARCH}.xml" \
  "${CLUSTER_PROFILE_DIR}/domain-template-${STREAM_ARCH}.xml" \
  "${CLUSTER_PROFILE_DIR}/domain-template.xml"; do
  if [[ -f "${candidate}" ]]; then
    RUN_TEMPLATE="${candidate}"
    break
  fi
done

if [[ -z "${INSTALL_TEMPLATE}" ]]; then
  echo "ERROR: Missing required ${ADDITIONAL_WORKER_ARCHITECTURE} install domain template in ${CLUSTER_PROFILE_DIR}"
  exit 1
fi

if [[ -z "${RUN_TEMPLATE}" ]]; then
  echo "ERROR: Missing required ${ADDITIONAL_WORKER_ARCHITECTURE} run domain template in ${CLUSTER_PROFILE_DIR}"
  exit 1
fi

# Validate template contents match expected QEMU architecture
if ! grep -q "${STREAM_ARCH}" "${INSTALL_TEMPLATE}"; then
  echo "ERROR: ${INSTALL_TEMPLATE} does not contain arch='${STREAM_ARCH}'"
  exit 1
fi

if ! grep -q "${STREAM_ARCH}" "${RUN_TEMPLATE}"; then
  echo "ERROR: ${RUN_TEMPLATE} does not contain arch='${STREAM_ARCH}'"
  exit 1
fi

HOSTNAME_PRIMARY="$(leaseLookup 'hostname')"
HOSTNAME_ADDITIONAL="$(leaseLookup 'hostname-additional')"
HTTPD_IP="$(leaseLookup 'httpd-ip')"
HTTPD_PORT="$(leaseLookup 'httpd-port')"
leaseLookup 'subnet' >/dev/null

ADDITIONAL_PORT="${ADDITIONAL_LIBVIRT_PORT:-16509}"
if [[ ! "${ADDITIONAL_PORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Invalid ADDITIONAL_LIBVIRT_PORT '${ADDITIONAL_PORT}'"
  exit 1
fi

PRIMARY_LIBVIRT_URI="qemu+tcp://${HOSTNAME_PRIMARY}/system"
ADDITIONAL_LIBVIRT_URI="qemu+tcp://${HOSTNAME_ADDITIONAL}:${ADDITIONAL_PORT}/system"

VIRSH_PRIMARY="mock-nss.sh virsh --connect ${PRIMARY_LIBVIRT_URI}"
VIRSH_ADDITIONAL="mock-nss.sh virsh --connect ${ADDITIONAL_LIBVIRT_URI}"

# Must match POOL_NAME used by the primary upi-install-libvirt step.
POOL_NAME="${POOL_NAME:-multiarch-ci-pool}"
ADDITIONAL_POOL="${ADDITIONAL_POOL_NAME:-multiarch-ci-pool}"
HTTPD_POOL="${HTTPD_POOL_NAME:-httpd}"
HTTPD_BASE_URL="http://${HTTPD_IP}:${HTTPD_PORT}"

# ---------------------------------------------------------------------------
# Additional-host libvirt network — attach to the infra VXLAN bridge rather
# than pointing guests at the primary NAT network (which only exists on Z).
# Bridge name is published by the network step (SHARED_DIR/additional-bridge-name
# or legacy arm-bridge-name). Working ARM path uses ocp2-arm; AMD leases use
# ocp1-amd / ocp3-amd.
# ---------------------------------------------------------------------------
ADDITIONAL_BRIDGE_FILE=""
for candidate in \
  "${SHARED_DIR}/additional-bridge-name" \
  "${SHARED_DIR}/arm-bridge-name"; do
  if [[ -f "${candidate}" ]]; then
    ADDITIONAL_BRIDGE_FILE="${candidate}"
    break
  fi
done
if [[ -z "${ADDITIONAL_BRIDGE_FILE}" ]]; then
  echo "ERROR: additional-bridge-name not found in SHARED_DIR; ensure the network step ran successfully"
  exit 1
fi
ADDITIONAL_BRIDGE_NAME="$(< "${ADDITIONAL_BRIDGE_FILE}")"
ADDITIONAL_BRIDGE_NAME="${ADDITIONAL_BRIDGE_NAME//$'\n'/}"
if [[ -z "${ADDITIONAL_BRIDGE_NAME}" || "${ADDITIONAL_BRIDGE_NAME}" =~ [^a-zA-Z0-9_-] ]]; then
  echo "ERROR: ADDITIONAL_BRIDGE_NAME '${ADDITIONAL_BRIDGE_NAME}' from SHARED_DIR is empty or has unexpected characters"
  exit 1
fi

# Domain templates historically substitute ${LEASED_RESOURCE} / ${NETWORK_NAME}.
# Create a lease-named libvirt network on the additional host that bridge-forwards
# to the infra VXLAN bridge (same pattern as the passing arm64 rehearse).
ADDITIONAL_NETWORK_NAME="${LEASED_RESOURCE}"
ADDITIONAL_NETWORK_XML="${SHARED_DIR}/network-additional.xml"

ADD_DEFINED_NETWORKS=$(${VIRSH_ADDITIONAL} net-list --all --name)
if echo "${ADD_DEFINED_NETWORKS}" | grep -Fxq "${ADDITIONAL_NETWORK_NAME}"; then
  echo "ERROR: Libvirt network '${ADDITIONAL_NETWORK_NAME}' already exists on additional hypervisor;" \
       " pre-cleanup is required before redefining it"
  exit 1
fi

echo "Creating additional-host libvirt network XML (bridge-forward to ${ADDITIONAL_BRIDGE_NAME})..."
cat > "${ADDITIONAL_NETWORK_XML}" <<EOF
<network>
  <name>${ADDITIONAL_NETWORK_NAME}</name>
  <forward mode='bridge'/>
  <bridge name='${ADDITIONAL_BRIDGE_NAME}'/>
</network>
EOF

echo "Defining additional libvirt network '${ADDITIONAL_NETWORK_NAME}' on additional hypervisor..."
${VIRSH_ADDITIONAL} net-define "${ADDITIONAL_NETWORK_XML}" --validate
${VIRSH_ADDITIONAL} net-start "${ADDITIONAL_NETWORK_NAME}"
# No autostart: lease-owned wrapper; infra owns the underlying VXLAN bridge.
export NETWORK_NAME="${ADDITIONAL_NETWORK_NAME}"
export LEASED_RESOURCE

ADD_NET_STATE=$(${VIRSH_ADDITIONAL} net-info "${ADDITIONAL_NETWORK_NAME}" | awk '/^Active:/{print $2}')
if [[ "${ADD_NET_STATE}" != "yes" ]]; then
  echo "ERROR: Additional libvirt network '${ADDITIONAL_NETWORK_NAME}' did not become active (state=${ADD_NET_STATE})"
  exit 1
fi
ADD_NET_BRIDGE=$(${VIRSH_ADDITIONAL} net-dumpxml "${ADDITIONAL_NETWORK_NAME}" |
  yq-v4 -p=xml --xml-attribute-prefix='@' -oy '.network.bridge."@name"')
if [[ "${ADD_NET_BRIDGE}" != "${ADDITIONAL_BRIDGE_NAME}" ]]; then
  echo "ERROR: Additional network XML references bridge '${ADD_NET_BRIDGE}', expected '${ADDITIONAL_BRIDGE_NAME}'"
  exit 1
fi
echo "Additional libvirt network '${ADDITIONAL_NETWORK_NAME}' active and referencing bridge '${ADDITIONAL_BRIDGE_NAME}'."

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
  # RHCOS live install over VXLAN can exceed 10m; allow 25m before failing (matches arm64).
  local wait_until=$(($(date +%s) + 1500))

  echo "[$(date -Is)] waiting for install domain ${domain} to complete and power off..."
  until [ $((wait_until - $(date +%s))) -le 0 ] || ! (${VIRSH_ADDITIONAL} domid "$domain" > /dev/null 2>&1); do
    sleep 5
  done
  if [ $((wait_until - $(date +%s))) -le 0 ]; then
    echo "ERROR: install domain ${domain} did not shut down before timeout (1500s)."
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
        local signer_name requester
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

# Fetch coreos boot images from the running cluster
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}"
  exit 1
fi

echo "Fetching coreos-bootimages for architecture ${STREAM_ARCH}..."
KERNEL_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${STREAM_ARCH}.artifacts.metal.formats.pxe.kernel.location")
INITRAMFS_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${STREAM_ARCH}.artifacts.metal.formats.pxe.initramfs.location")
ROOTFS_URL=$(oc -n openshift-machine-config-operator get configmap/coreos-bootimages -o jsonpath='{.data.stream}' | yq-v4 -oy ".architectures.${STREAM_ARCH}.artifacts.metal.formats.pxe.rootfs.location")

if [[ -z "${KERNEL_URL}" || "${KERNEL_URL}" == "null" || -z "${INITRAMFS_URL}" || "${INITRAMFS_URL}" == "null" || -z "${ROOTFS_URL}" || "${ROOTFS_URL}" == "null" ]]; then
  echo "ERROR: Failed to retrieve boot artifact URLs from coreos-bootimages configmap for ${STREAM_ARCH}"
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

# Stage kernel and initramfs to additional hypervisor's boot pool / scratch.
# Preferred path for new volumes; actual path is resolved via vol-path below.
HOST_BOOT_ARTIFACT_BASE=/var/lib/libvirt/images/openshift-images/
UPLOAD_PATH_KERNEL=${HOST_BOOT_ARTIFACT_BASE}${KERNEL_FILENAME}
UPLOAD_PATH_INITRAMFS=${HOST_BOOT_ARTIFACT_BASE}${INITRAMFS_FILENAME}

if check_exists_in_additional_pool "${ADDITIONAL_POOL}" "$KERNEL_FILENAME"; then
  echo "kernel ($KERNEL_FILENAME) already exists in ${ADDITIONAL_POOL} on additional host, skipping transfer"
else
  echo "Downloading kernel..."
  curl -sSfL -o "/tmp/$KERNEL_FILENAME" "$KERNEL_URL"
  if [[ ! -s "/tmp/$KERNEL_FILENAME" ]]; then
    echo "ERROR: Downloaded kernel file is empty"
    exit 1
  fi
  upload_to_additional_pool "${ADDITIONAL_POOL}" "/tmp/$KERNEL_FILENAME" "${KERNEL_FILENAME}" "$UPLOAD_PATH_KERNEL"
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
  upload_to_additional_pool "${ADDITIONAL_POOL}" "/tmp/$INITRAMFS_FILENAME" "${INITRAMFS_FILENAME}" "$UPLOAD_PATH_INITRAMFS"
  rm -f "/tmp/$INITRAMFS_FILENAME"
fi

# Resolve real volume paths from the pool target (dir pools ignore <target><path>).
HOST_PATH_KERNEL="$(${VIRSH_ADDITIONAL} vol-path --pool "${ADDITIONAL_POOL}" "${KERNEL_FILENAME}")"
HOST_PATH_INITRAMFS="$(${VIRSH_ADDITIONAL} vol-path --pool "${ADDITIONAL_POOL}" "${INITRAMFS_FILENAME}")"
if [[ -z "${HOST_PATH_KERNEL}" || -z "${HOST_PATH_INITRAMFS}" ]]; then
  echo "ERROR: Failed to resolve kernel/initramfs volume paths in pool ${ADDITIONAL_POOL}"
  exit 1
fi
echo "Boot artifacts on additional host: kernel=${HOST_PATH_KERNEL} initramfs=${HOST_PATH_INITRAMFS}"

# Provision additional compute nodes
ADD_COMPUTE_COUNT=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"additional-compute\" | length" "${LEASE_CONF}")
echo "Provisioning ${ADD_COMPUTE_COUNT} additional ${ADDITIONAL_WORKER_ARCHITECTURE} compute nodes..."

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

  DOMAIN_UUID="$(uuidgen)"
  export DOMAIN_NAME="${node_name}"
  export DOMAIN_UUID
  export DOMAIN_MEMORY="${DOMAIN_MEMORY}"
  export DOMAIN_VCPUS="${DOMAIN_VCPUS}"
  export HOST_PATH_KERNEL="${HOST_PATH_KERNEL}"
  export HOST_PATH_INITRAMFS="${HOST_PATH_INITRAMFS}"
  export DOMAIN_CMDLINE="${domain_cmdline}"
  export DISK_SOURCE_PATH="${domain_qcow2_image_host_path}"
  export MAC_ADDRESS="${node_mac}"
  export NETWORK_NAME="${ADDITIONAL_NETWORK_NAME}"
  # amd64 VPN domain templates use ${ADDITIONAL_NETWORK_NAME}; arm templates may use NETWORK_NAME/LEASED_RESOURCE.
  export ADDITIONAL_NETWORK_NAME
  export DOMAIN_MAC="${node_mac}"
  export LEASED_RESOURCE

  # Whitelist — cover all network var names used by cluster-profile domain templates.
  TEMPLATE_VARS='$DOMAIN_NAME $DOMAIN_UUID $DOMAIN_MEMORY $DOMAIN_VCPUS $HOST_PATH_KERNEL $HOST_PATH_INITRAMFS $DOMAIN_CMDLINE $DISK_SOURCE_PATH $MAC_ADDRESS $NETWORK_NAME $ADDITIONAL_NETWORK_NAME $LEASED_RESOURCE $DOMAIN_MAC'

  echo "Rendering install domain XML for ${node_name} (network=${NETWORK_NAME}, bridge=${ADDITIONAL_BRIDGE_NAME}, memory_kib=${DOMAIN_MEMORY}, vcpus=${DOMAIN_VCPUS})..."
  domain_install_xml=$(mktemp --tmpdir domain-"${node_name}"-install.xml.XXXXX)
  envsubst "${TEMPLATE_VARS}" < "${INSTALL_TEMPLATE}" > "${domain_install_xml}"

  echo "Defining and starting install domain for ${node_name}..."
  CURRENT_INSTALL_DOMAIN="${node_name}"
  if ! ${VIRSH_ADDITIONAL} create "${domain_install_xml}" --validate; then
    echo "ERROR: Failed to create install domain ${node_name}; dumping memory settings and host free memory..."
    grep -E '<memory|<currentMemory|vcpu' "${domain_install_xml}" || true
    ${VIRSH_ADDITIONAL} nodememstats 2>/dev/null || true
    ${VIRSH_ADDITIONAL} list --all 2>/dev/null || true
    cp -f "${domain_install_xml}" "${ARTIFACT_DIR}/domain-${node_name}-install-failed.xml" 2>/dev/null || true
    rm -f "${domain_install_xml}"
    exit 1
  fi
  rm -f "${domain_install_xml}"

  wait_for_domain_deletion "${node_name}"
  CURRENT_INSTALL_DOMAIN=""

  echo "Install domain deleted. Defining persistent run domain for ${node_name} that boots from disk..."
  domain_run_xml=$(mktemp --tmpdir domain-"${node_name}"-run.xml.XXXXX)
  DOMAIN_UUID="$(uuidgen)"
  export DOMAIN_UUID
  envsubst "${TEMPLATE_VARS}" < "${RUN_TEMPLATE}" > "${domain_run_xml}"

  ${VIRSH_ADDITIONAL} define "${domain_run_xml}" --validate
  ${VIRSH_ADDITIONAL} start "${node_name}"
  ${VIRSH_ADDITIONAL} autostart "${node_name}" || true
  rm -f "${domain_run_xml}"
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_HETEROGENEOUS_INSTALL_START_TIME"

echo "Approving pending CSRs for additional compute nodes..."
approve_csrs &
CSR_APPROVER_PID=$!

echo "Waiting for newly provisioned ${ADDITIONAL_WORKER_ARCHITECTURE} node(s) to join and become Ready..."
for (( idx=0; idx<ADD_COMPUTE_COUNT; idx++ )); do
  target_node_name="${LEASED_RESOURCE}-additional-compute-${idx}"
  echo "Checking node status for ${target_node_name}..."
  node_ready=false
  for (( i=1; i<=60; i++ )); do
    # Verify the specific node exists, matches expected architecture, and is Ready
    NODE_LINE=$(oc get nodes --no-headers 2>/dev/null | grep -E "^${target_node_name}(\.[a-zA-Z0-9.-]+)?\s+" || true)
    if [[ -n "${NODE_LINE}" ]] && echo "${NODE_LINE}" | grep -qw "Ready"; then
      NODE_ARCH=$(oc get node "$(echo "${NODE_LINE}" | awk '{print $1}')" -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null || true)
      if [[ "${NODE_ARCH}" == "${EXPECTED_NODE_ARCH}" ]]; then
        echo "Node ${target_node_name} successfully joined and is Ready with architecture ${EXPECTED_NODE_ARCH}."
        node_ready=true
        break
      fi
    fi
    sleep 10
  done
  if [[ "${node_ready}" != "true" ]]; then
    echo "ERROR: Timed out waiting for node ${target_node_name} to reach Ready state with ${EXPECTED_NODE_ARCH} architecture."
    exit 1
  fi
done

echo "Waiting for cluster operators to stabilize after adding ${ADDITIONAL_WORKER_ARCHITECTURE} worker..."
oc adm wait-for-stable-cluster

oc config refresh-ca-bundle || true

date "+%F %X" > "${SHARED_DIR}/CLUSTER_HETEROGENEOUS_INSTALL_END_TIME"
touch /tmp/heterogeneous-install-complete

echo "Heterogeneous ${ADDITIONAL_WORKER_ARCHITECTURE} worker provisioned and verified successfully."
