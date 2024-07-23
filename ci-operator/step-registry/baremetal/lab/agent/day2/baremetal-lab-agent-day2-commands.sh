#!/bin/bash

set -o errtrace
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR


[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"

if [ "${ADDITIONAL_WORKERS}" == "0" ]; then
    echo "No additional workers requested"
    exit 0
fi

if [ "${ADDITIONAL_WORKERS_DAY2}" != "true" ]; then
    echo "Skipping as the additional nodes have been provisioned at installation time."
    exit 0
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

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

function approve_csrs() {
  while [[ ! -f '/tmp/scale-out-complete' ]]; do
    sleep 30
    echo "approve_csrs() running..."
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
      | xargs --no-run-if-empty oc adm certificate approve || true
  done
}

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
    monitor_workers &
    ready_nodes=$(get_ready_nodes_count)
    if [ x"${ready_nodes}" == x"${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

function monitor_workers()
{
  local DAY2_IPS=""

  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
      DAY2_IPS+="${ip},"
    fi
  done
  DAY2_IPS=${DAY2_IPS%,}
  echo "Launching DAY2 workers monitoring ..."
  /tmp/oc adm node-image monitor --ip-addresses "${DAY2_IPS}" -a "${day2_pull_secret}"
}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

#BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
#PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret


INSTALL_DIR="${INSTALL_DIR:-/tmp/installer}"
mkdir -p "${INSTALL_DIR}"
day2_pull_secret="${INSTALL_DIR}/day2_pull_secret"


cat > "${INSTALL_DIR}/nodes-config.yaml" <<EOF
hosts: []
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then

  ADAPTED_YAML="
  hostname: ${name}
  interfaces:
  - macAddress: ${mac}
    name: ${baremetal_iface}
  networkConfig:
    interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: ${ipv4_enabled}
        dhcp: false
        address:
            - ip: ${ip}
              prefix-length: ${INTERNAL_NET_CIDR##*/}
      ipv6:
        enabled: ${ipv6_enabled}
"

  # Take care of the indentation when adding the dns and routes to the above yaml
  ADAPTED_YAML+="
    dns-resolver:
          config:
            server:
              - ${INTERNAL_NET_IP}
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-address: ${INTERNAL_NET_IP}
          next-hop-interface: ${baremetal_iface}
  "
  # Patch the nodes-config.yaml by adding the given host to the hosts list in the platform.baremetal stanza
  yq --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
    "$INSTALL_DIR/nodes-config.yaml" - <<< "$ADAPTED_YAML"
  fi
done

cp "${INSTALL_DIR}/nodes-config.yaml" "${ARTIFACT_DIR}/"

export KUBECONFIG="$SHARED_DIR/kubeconfig"
export http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}"

cat "${CLUSTER_PROFILE_DIR}/pull-secret" > "${day2_pull_secret}"

echo "Extract the latest oc client..."
oc adm release extract -a "${day2_pull_secret}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=oc --to=/tmp --insecure=true

if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-mirror.yaml.patch" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
  # use registry credential for disconnected auth
  grep "auths" "${SHARED_DIR}/install-config.yaml" > "${day2_pull_secret}"
  #oc get secret -n openshift-config pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${day2_pull_secret}"
fi

echo "Create node.iso for day2 worker nodes..."
/tmp/oc adm node-image create --dir="${INSTALL_DIR}" -a "${day2_pull_secret}" --insecure=true

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

gnu_arch=$(echo "$architecture" | sed 's/arm64/aarch64/;s/amd64/x86_64/;')
case "${BOOT_MODE}" in
"iso")
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the day2 node ISO image into the bastion host..."
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}/node.iso" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}.node.iso"
  echo -e "\nMounting the ISO image in the hosts via virtual media and powering on the hosts..."
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
      if [ "${transfer_protocol_type}" == "cifs" ]; then
        IP_ADDRESS="$(dig +short "${AUX_HOST}")"
        iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}.node.iso"
      else
        # Assuming HTTP or HTTPS
        iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/${CLUSTER_NAME}.node.iso"
      fi
      mount_virtual_media "${host}" "${iso_path}"
    fi
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

EXPECTED_NODES=$(( $(get_ready_nodes_count) + ADDITIONAL_WORKERS ))

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    echo "Power on #${host} (${name})..."
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"
  fi
done

echo "Monitoring day2 workers and approve csrs..."
approve_csrs &
wait_for_nodes_readiness ${EXPECTED_NODES}
ret="$?"
if [ "${ret}" != "0" ]; then
  echo "Some errors occurred, exiting with ${ret}."
  exit "${ret}"
fi

rm -f "${day2_pull_secret}"
# let the approve_csr function finish
touch /tmp/scale-out-complete



