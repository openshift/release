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
  ### Sushy doesn't support NFS as TransferProtcolType, and some servers' BMCs (in particular the ones of the arm64 servers)
  ##  are not 100% compliant with the Redfish standard. Therefore, relying on the raw redfish python library.
  local bmc_address="${1}"
  local bmc_username="${2}"
  local bmc_password="${3}"
  local iso_path="${4}"
  local transfer_protocol_type="${5}"
  echo "Mounting the ISO image in ${bmc_address} via virtual media..."
  python3 -u - "${bmc_address}" "${bmc_username}" "${bmc_password}" \
    "${iso_path}" "${transfer_protocol_type^^}" <<'EOF'
import redfish
import sys
import time

bmc_address = sys.argv[1]
bmc_username = sys.argv[2]
bmc_password = sys.argv[3]
iso_path = sys.argv[4]
transfer_protocol_type = sys.argv[5]

def redfish_mount_remote(context):
    response = context.post(f"/redfish/v1/Managers/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.InsertMedia",
                        body={"Image": iso_path, "TransferProtocolType": transfer_protocol_type,
                              "Inserted": True, **other_options})
    print(f"/redfish/v1/Managers/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.InsertMedia")
    print({"Image": iso_path, "TransferProtocolType": transfer_protocol_type})
    imageIsMounted = False
    print(response.status)
    print(response.text)
    if response.status > 299:
        sys.exit(1)
    d = {}
    task = None
    if response.is_processing:
        while task is None or (task is not None and
                            (task.is_processing or not task.dict.get("TaskState") in ("Completed", "Exception"))):
            task = response.monitor(context)
            print("Task target: %s" % bmc_address)
            print("Task is_processing: %s" % task.is_processing)
            print("Task state: %s " % task.dict.get("TaskState"))
            print("Task status: %s" % task.status)
            retry_time = task.retry_after
            time.sleep(retry_time if retry_time else 5)
            if (task.dict.get("TaskState") in ("Completed")):
              imageIsMounted = True
        if task.status > 299:
            print()
            sys.exit(1)
        print()
    return imageIsMounted

context = redfish.redfish_client(bmc_address, username=bmc_username, password=bmc_password, max_retry=20)
context.login(auth=redfish.AuthMethod.BASIC)
response = context.get("/redfish/v1/Managers/")
manager = response.dict.get("Members")[0]["@odata.id"].split("/")[-1]
response = context.get(f"/redfish/v1/Managers/{manager}/VirtualMedia/")
removable_disk = list(filter((lambda x: x["@odata.id"].find("CD") != -1),
                             response.dict.get("Members")))[0]["@odata.id"].split("/")[-1]

### This is for AMI BMCs (currently only the arm64 servers) as they are affected by a bug that prevents the ISOs to be mounted/umounted
### correctly. The workaround is to reset the redfish internal redis database and make it populate again from the BMC.
if manager == "Self":
  print(f"Reset {bmc_address} BMC's redfish database...")
  try:
    response = context.post(f"/redfish/v1/Managers/{manager}/Actions/Oem/AMIManager.RedfishDBReset/",
                            body={"RedfishDBResetType": "ResetAll"})
    # Wait for the BMC to reset the database
    time.sleep(60)
  except Exception as e:
    print("Failed to reset the BMC's redfish database. Continuing anyway...")
  print("Reset BMC and wait for 5mins to be reachable again...")
  try:
    response = context.post(f"/redfish/v1/Managers/{manager}/Actions/Manager.Reset",
                            body={"ResetType": "ForceRestart"})
    # Wait for the BMC to reset
    time.sleep(300)
  except Exception as e:
    print("Failed to reset the BMC. Continuing anyway...")

print("Eject virtual media, if any...")
response = context.post(
    f"/redfish/v1/Managers/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.EjectMedia", body={})
print(response.text)
time.sleep(30)
print("Insert new virtual media...")

other_options = {}
if transfer_protocol_type == "CIFS":
  other_options = {"UserName": "root", "Password": bmc_password}

retry_counter = 0
max_retries = 6
imageIsMounted = False

while retry_counter < max_retries and not imageIsMounted:
  imageIsMounted = redfish_mount_remote(context)
  retry_counter=retry_counter+1

print(f"Logging out of {bmc_address}")
context.logout()

if not imageIsMounted:
  print("Max retries, failing")
  sys.exit(1)


EOF
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in ${bmc_address} via virtual media."
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

function reset_host() {
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  local vendor="${4:-ampere}"
  ipmi_boot_selection=$([ "${BOOT_MODE}" == "pxe" ] && echo force_pxe || echo force_cdrom)
  sushy_boot_selection=$([ "${BOOT_MODE}" == "pxe" ] && echo PXE || echo VCD-DVD)
  echo "Resetting the host ${bmc_address}..."
  case "${vendor}" in
    ampere)
      ipmitool -I lanplus -H "$bmc_address" \
        -U "$bmc_user" -P "$bmc_pass" \
        chassis bootparam set bootflag "$ipmi_boot_selection" options=PEF,watchdog,reset,power
    ;;
    dell)
      # this is how sushy does it
      curl -k -u "${bmc_user}:${bmc_pass}" -X POST \
        "https://$bmc_address/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration" \
         -H "Content-Type: application/json" -d \
         '{"ShareParameters":{"Target":"ALL"},"ImportBuffer":
            "<SystemConfiguration><Component FQDD=\"iDRAC.Embedded.1\">
            <Attribute Name=\"ServerBoot.1#BootOnce\">Enabled</Attribute>
            <Attribute Name=\"ServerBoot.1#FirstBootDevice\">'"$sushy_boot_selection"'</Attribute>
            </Component></SystemConfiguration>"}'
    ;;
    *)
      echo "Unknown vendor ${vendor}"
      return 1
  esac
  ipmitool -I lanplus -H "$bmc_address" \
    -U "$bmc_user" -P "$bmc_pass" \
    power off || echo "Already off"
  # If the host is not already powered off, the power on command can fail while the host is still powering off.
  # Let's retry the power on command multiple times to make sure the command is received in the correct state.
  for i in {1..10} max; do
    if [ "$i" == "max" ]; then
      echo "Failed to reset $bmc_address"
      return 1
    fi
    ipmitool -I lanplus -H "$bmc_address" \
      -U "$bmc_user" -P "$bmc_pass" \
      power on && break
    echo "Failed to power on $bmc_address, retrying..."
    sleep 5
  done
}

function update_image_registry() {
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

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"
API_VIP="$(yq ".api_vip" "${SHARED_DIR}/vips.yaml")"
INGRESS_VIP="$(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")"
mkdir -p "${INSTALL_DIR}"

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

# We change the payload image to the one in the mirror registry only when the mirroring happens.
# For example, in the case of clusters using cluster-wide proxy, the mirroring is not required.
# To avoid additional params in the workflows definition, we check the existence of the ICSP patch file.
if [ "${DISCONNECTED}" == "true" ] && [ -f "${SHARED_DIR}/install-config-icsp.yaml.patch" ]; then
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
networking:
  machineNetwork:
  - cidr: ${INTERNAL_NET_CIDR}
controlPlane:
   architecture: ${architecture}
   hyperthreading: Enabled
   name: master
   replicas: ${masters}
"

if [ "${masters}" -eq 1 ]; then
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
platform:
  none: {}
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: 0
"
fi

if [ "${masters}" -gt 1 ]; then
  if [ "${AGENT_PLATFORM_TYPE}" = "none" ]; then
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}
platform:
  none: {}
"
  else
  yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<< "
compute:
- architecture: ${architecture}
  hyperthreading: Enabled
  name: worker
  replicas: ${workers}
platform:
  baremetal:
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
"
  fi
fi

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
    if [ "${transfer_protocol_type}" == "cifs" ]; then
      IP_ADDRESS="$(dig +short "${AUX_HOST}")"
      iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}.${arch}.iso"
    else
      # Assuming HTTP or HTTPS
      iso_path="${transfer_protocol_type}://${AUX_HOST}/${CLUSTER_NAME}.${arch}.iso"
    fi
    mount_virtual_media "${bmc_address}" "${redfish_user}" "${redfish_password}" \
      "${iso_path}" "${transfer_protocol_type}" &
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
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/pxe/agent.*-vmlinuz* \
    "root@${AUX_HOST}:/opt/tftpboot/${CLUSTER_NAME}/vmlinuz_${gnu_arch}"
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/pxe/agent.*-initrd* \
    "root@${AUX_HOST}:/opt/tftpboot/${CLUSTER_NAME}/initramfs_${gnu_arch}.img"
  scp "${SSHOPTS[@]}" "${INSTALL_DIR}"/pxe/agent.*-rootfs* \
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

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "Power on ${bmc_address//.*/} (${name})..."
  reset_host "${bmc_address}" "${bmc_user}" "${bmc_pass}" "${vendor}"
done

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
echo -e "\nForcing 15min delay to allow instances to properly boot up (long PXE boot times & console-hook) - NOTE: unnecessary overtime will be reduced from total bootstrap time."
sleep 900
echo "Launching 'wait-for bootstrap-complete' installation step....."
# The installer uses the rendezvous IP for checking the bootstrap phase.
# The rendezvous IP is in the internal net in our lab.
# Let's use a proxy here as the internal net is not routable from the container running the installer.
proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst agent wait-for bootstrap-complete 2>&1 &
if ! wait $!; then
  # TODO: gather logs??
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

update_image_registry &
echo -e "\nLaunching 'wait-for install-complete' installation step....."
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst agent wait-for install-complete &
if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  # TODO: gather logs??
  exit 1
fi
