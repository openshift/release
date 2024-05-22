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


SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret

INSTALL_DIR="${INSTALL_DIR:-/tmp/installer}"
DAY2_ASSETS_DIR="${DAY2_ASSETS_DIR:-/tmp/installer/assets}"

mkdir -p "${INSTALL_DIR}"
mkdir -p "${DAY2_ASSETS_DIR}"


cat > "${DAY2_ASSETS_DIR}/nodes-config.yaml" <<EOF
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
    "$DAY2_ASSETS_DIR/nodes-config.yaml" - <<< "$ADAPTED_YAML"
  fi
done

cp "${DAY2_ASSETS_DIR}/nodes-config.yaml" "${ARTIFACT_DIR}/"

# node-joiner-monitor.sh needs write permissions
cp "$SHARED_DIR/kubeconfig" "${DAY2_ASSETS_DIR}/"

export KUBECONFIG="$DAY2_ASSETS_DIR/kubeconfig"

curl https://raw.githubusercontent.com/bmanzari/installer/AGENT-912/docs/user/agent/add-node/node-joiner.sh --output "${DAY2_ASSETS_DIR}/node-joiner.sh"

curl https://raw.githubusercontent.com/bmanzari/installer/AGENT-912/docs/user/agent/add-node/node-joiner-monitor.sh --output "${DAY2_ASSETS_DIR}/node-joiner-monitor.sh"

export http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}"

chmod +x "${DAY2_ASSETS_DIR}/node-joiner.sh"
chmod +x "${DAY2_ASSETS_DIR}/node-joiner-monitor.sh"

sh "${DAY2_ASSETS_DIR}/node-joiner.sh" "$DAY2_ASSETS_DIR/nodes-config.yaml"

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")



gnu_arch=$(echo "$architecture" | sed 's/arm64/aarch64/;s/amd64/x86_64/;')
case "${BOOT_MODE}" in
"iso")
  ### Create ISO image
  #echo -e "\nCreating image..."
  #oinst agent create image
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the day2 node ISO image into the bastion host..."
  scp "${SSHOPTS[@]}" "${DAY2_ASSETS_DIR}/node.x86_64.iso" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}.node.iso"
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


# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "${name}" == *-a-* ]] && [ "${ADDITIONAL_WORKERS_DAY2}" == "true" ]; then
    echo "Power on #${host} (${name})..."
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"
  fi
done

sh "${DAY2_ASSETS_DIR}/node-joiner-monitor.sh"


sleep 7200
