#!/bin/bash

set -o errtrace
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
trap 'FRC=$?; createHeterogeneousJunit; debug' EXIT TERM

# Print failed node, co, machine information for debug purpose
function debug() {
  if (( FRC != 0 )); then
    echo -e "Describing abnormal nodes...\n"
    oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
    echo -e "Describing abnormal operators...\n"
    oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
  fi
}

# Generate the Junit for migration
function createHeterogeneousJunit() {
  echo "Generating the Junit for agent day2"
  filename="import-Agent_Day2"
  testsuite="Agent_Day2"
  if (( FRC == 0 )); then
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
  <testcase name="OCP-00001:zniu:Adding day2 worker nodes should succeed"/>
</testsuite>
EOF
  else
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
  <testcase name="OCP-00001:zniu:Adding day2 worker nodes should succeed">
    <failure message="">add day2 worker nodes failed or cluster operators abnormal after the new nodes joined the cluster</failure>
  </testcase>
</testsuite>
EOF
  fi
}


[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && { echo "\$workers is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && { echo "\$masters is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
   source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ "${ADDITIONAL_WORKERS}" == "0" ]; then
   echo "No additional workers requested"
   exit 0
fi

if [ "${ADDITIONAL_WORKERS_DAY2}" != "true" ]; then
   echo "Skipping as the additional nodes have been provisioned at installation time."
   exit 0
fi

total_workers="${ADDITIONAL_WORKERS_DAY2}"

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

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")


export KUBECONFIG="$SHARED_DIR/kubeconfig"

day2_pull_secret="${SHARED_DIR}/day2_pull_secret"
cat "${CLUSTER_PROFILE_DIR}/pull-secret" > "${day2_pull_secret}"

echo "Extract the latest oc client..."
oc adm release extract -a "${day2_pull_secret}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=oc --to=/tmp --insecure=true

if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-mirror.yaml.patch" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
  oc get secret -n openshift-config pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${day2_pull_secret}"
fi

DAY2_INSTALL_DIR="${DAY2_INSTALL_DIR:-/tmp/installer_day2}"
mkdir -p "${DAY2_INSTALL_DIR}"
cp "${SHARED_DIR}/nodes-config.yaml" "${DAY2_INSTALL_DIR}/"
cp "${SHARED_DIR}/nodes-config.yaml" "${ARTIFACT_DIR}/"

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
arch=${ADDITIONAL_WORKER_ARCHITECTURE}

case "${BOOT_MODE}" in
"iso")
  ### Create iso file
  echo -e "\nCreate node.iso for day2 worker nodes..."
  /tmp/oc adm node-image create --dir="${DAY2_INSTALL_DIR}" -a "${day2_pull_secret}" --insecure=true
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the day2 node ISO image into the bastion host..."
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}/node.${arch}.iso" "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}.node.iso"
  echo -e "\nMounting the ISO image in the hosts via virtual media and powering on the hosts..."
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[] | select(.name|test("-a-"))' "${SHARED_DIR}/hosts.yaml"); do
   # shellcheck disable=SC1090
   . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
   if [ "${transfer_protocol_type}" == "cifs" ]; then
     IP_ADDRESS="$(dig +short "${AUX_HOST}")"
     iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}.node.iso"
   else
     # Assuming HTTP or HTTPS
     iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/${CLUSTER_NAME}.node.iso"
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
  echo -e "\nCreate pxe files for day2 worker nodes..."
  /tmp/oc adm node-image create --pxe --dir="${DAY2_INSTALL_DIR}" -a "${day2_pull_secret}" --insecure=true
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the PXE files into the bastion host..."
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/node.*-vmlinuz* \
   "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/vmlinuz_${arch}_2"
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/node.*-initrd* \
   "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/initramfs_${arch}_2.img"
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/node.*-rootfs* \
   "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/rootfs-${arch}_2.img"
;;
*)
  echo "Unknown install mode: ${BOOT_MODE}"
  exit 1
esac

day2_IPs=""

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[] | select(.name|test("-a-"))' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  day2_IPs+="${ip},"
  echo "Power on #${host} (${name})..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"
done

day2_IPs=${day2_IPs%,}
touch /tmp/output.txt

function wait_for_text_and_approve_csrs() {
  local text="$1"
  for ((i=0; i<10; i++)); do
    count=$(grep -o "'$text'" /tmp/output.txt | wc -l | tr -d ' ')
    count=${count:-0}
    if [ "$count" -eq "$total_workers" ]; then
      echo "'$text' count matches the total workers count. Approving CSRs..."
      sleep 10
      pending_csrs=$(oc get csr | grep Pending | awk '{print $1}')
      for csr in $pending_csrs; do
        echo "Approving CSR: $csr"
        oc adm certificate approve "$csr"
      done
      break
    fi

    echo "Waiting 30s before next check..."
    sleep 30
  done
}

echo "Monitoring additional worker nodes IPs ${day2_IPs} to join the cluster"
sleep 60
oc adm node-image monitor --ip-addresses "${day2_IPs}" -a "${day2_pull_secret}" --insecure=true 2>&1 | tee /tmp/output.txt &
echo "Adding a 30-minute delay to allow all worker nodes to reach the state 'Kubelet is running'."
sleep 30m

wait_for_text_and_approve_csrs "Kubelet"
echo "Approving next sets of CSRs..."
wait_for_text_and_approve_csrs "Node joined"

EXIT_STATUS="${PIPESTATUS[0]}"
rm -f "${day2_pull_secret}"
if [[ $EXIT_STATUS != 0 ]]; then
  echo "Exiting with status $EXIT_STATUS"
  exit $EXIT_STATUS
fi

# Add operators status checking until monitoring enhanced to do this
echo "Check all cluster operators get stable and ready"
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=15m