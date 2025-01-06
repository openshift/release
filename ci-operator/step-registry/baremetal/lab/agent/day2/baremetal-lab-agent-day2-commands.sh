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

function get_oc_skew() {
  LATEST_SKEW_OC_RELEASE=""

  case "${ADDITIONAL_WORKER_ARCHITECTURE}" in
  "x86_64")
      #  https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest?prefix=4.17
      #  LATEST_SKEW_OC_RELEASE=$(curl -s "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest?prefix=${OC_SKEW_VERSION}")
      LATEST_SKEW_OC_RELEASE=$(curl -s "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/${OC_SKEW_VERSION}.0-0.nightly/latest")
  ;;
  "aarch64")
      #  https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-multi/latest?prefix=4.17
      #LATEST_SKEW_OC_RELEASE=$(curl -s "https://multi.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable-multi/latest?prefix=${OC_SKEW_VERSION}")
      LATEST_SKEW_OC_RELEASE=$(curl -s "https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream/${OC_SKEW_VERSION}.0-0.nightly-arm64/latest")
  ;;
  *)
    echo "Unknown arch: ${ADDITIONAL_WORKER_ARCHITECTURE}"
    exit 1
  esac

  # {
  # "name": "4.17.9",
  # "phase": "Accepted",
  # "pullSpec": "quay.io/openshift-release-dev/ocp-release:4.17.9-x86_64",
  # "downloadURL": "https://openshift-release-artifacts.apps.ci.l2s4.p1.openshiftapps.com/4.17.9"
  # }

  pull_spec=$(echo "$LATEST_SKEW_OC_RELEASE" | jq -r '.pullSpec')
  echo "oc skew pull spec: $pull_spec"

  echo "Extract the skew oc client..."
  oc adm release extract -a "${day2_pull_secret}" "${pull_spec}" \
    --command=oc --to=/tmp --insecure=true
}

export KUBECONFIG="$SHARED_DIR/kubeconfig"

day2_pull_secret="${SHARED_DIR}/day2_pull_secret"
cat "${CLUSTER_PROFILE_DIR}/pull-secret" > "${day2_pull_secret}"

## If no oc skew version is specified, use same version as current ocp payload

if [ -z "${OC_SKEW_VERSION}" ]; then
  echo "Extract the latest oc client..."
  oc adm release extract -a "${day2_pull_secret}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
    --command=oc --to=/tmp --insecure=true
else
  echo "Skew test, downloading oc skew binary version ${OC_SKEW_VERSION}"
  get_oc_skew
fi

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

/tmp/oc version | tee "${ARTIFACT_DIR}/oc_version.txt"

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
  # The --report and --pxe flags were introduced in 4.18. It should be marked as experimental until 4.19.
  /tmp/oc adm node-image create --report=true --pxe --dir="${DAY2_INSTALL_DIR}" -a "${day2_pull_secret}" --insecure=true

  # oc adm node-image create --pxe does not generate only pxe artifacts, but copies everything from the node-joiner pod.
  # Also, the name of the pxe artifacts are not corrected (prefixed with agent, instead of node)
  ls -lR "${DAY2_INSTALL_DIR}" > "${ARTIFACT_DIR}/pxe_artifacts_names.txt"

  cp "${DAY2_INSTALL_DIR}/report.json" "${ARTIFACT_DIR}/"

  # In the target folder, there should be only the following artifacts:
  # * node.x86_64-initrd.img
  # * node.x86_64-rootfs.img
  # * node.x86_64-vmlinuz
  ### Copy the image to the auxiliary host
  echo -e "\nCopying the PXE files into the bastion host..."
  #scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/boot-artifacts/*-vmlinuz* \
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/*-vmlinuz* \
   "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/vmlinuz_${arch}_2"
  #scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/boot-artifacts/*-initrd* \
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/*-initrd* \
   "root@${AUX_HOST}:/opt/dnsmasq/tftpboot/${CLUSTER_NAME}/initramfs_${arch}_2.img"
  #scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/boot-artifacts/*-rootfs* \
  scp "${SSHOPTS[@]}" "${DAY2_INSTALL_DIR}"/*-rootfs* \
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

echo "Monitoring day2 workers and pending CSRs..."

/tmp/oc adm node-image monitor --ip-addresses "${day2_IPs}" -a "${day2_pull_secret}" --insecure=true 2>&1 | \
  tee /tmp/output.txt | while IFS= read -r line; do
  echo "$line"
  if [[ "$line" = *"with signerName kubernetes.io/kube-apiserver-client-kubelet and username system:serviceaccount:openshift-machine-config-operator:node-bootstrapper is Pending and awaiting approval"* ]] || [[ "$line" = *"with signerName kubernetes.io/kubelet-serving and username "*" is Pending and awaiting approval"* ]]; then
    node_ip=$(echo "$line" | sed 's/^.*Node \(.*\): CSR.*$/\1/')
    csr=$(echo "$line" | sed 's/^.*CSR \([^ ]*\).*$/\1/')
    echo "Approving CSR $csr for node $node_ip"
    oc adm certificate approve "$csr"
  fi
done

EXIT_STATUS="${PIPESTATUS[0]}"
rm -f "${day2_pull_secret}"
if [[ $EXIT_STATUS != 0 ]]; then
  echo "Exiting with status $EXIT_STATUS"
  exit $EXIT_STATUS
fi

# Add operators status checking until monitoring enhanced to do this
echo "Check all cluster operators get stable and ready"
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=15m