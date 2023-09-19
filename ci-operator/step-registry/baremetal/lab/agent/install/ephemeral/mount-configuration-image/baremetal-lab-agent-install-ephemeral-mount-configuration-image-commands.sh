#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset
set -x

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }


if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#Mount the agent configuration ISO image in Virtual Media Slot 2 using RedFish 'Systems' and fixed removable device enumerator

function mount_agent_configuration_image() {
  ### Sushy doesn't support NFS as TransferProtcolType, and some servers' BMCs (in particular the ones of the arm64 servers)
  ##  are not 100% compliant with the Redfish standard. Therefore, relying on the raw redfish python library.
  local bmc_address="${1}"
  local bmc_username="${2}"
  local bmc_password="${3}"
  local iso_path="${4}"
  local transfer_protocol_type="${5}"
  echo "Mounting the agent configuration ISO image in ${bmc_address} via virtual media..."
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

context = redfish.redfish_client(bmc_address, username=bmc_username, password=bmc_password)
context.login(auth=redfish.AuthMethod.BASIC)
response = context.get("/redfish/v1/Systems/")
manager = response.dict.get("Members")[0]["@odata.id"].split("/")[-1]
response = context.get(f"/redfish/v1/Systems/{manager}/VirtualMedia/")
removable_disk = 2

### This is for AMI BMCs (currently only the arm64 servers) as they are affected by a bug that prevents the ISOs to be mounted/umounted
### correctly. The workaround is to reset the redfish internal redis database and make it populate again from the BMC.
if manager == "Self":
  print("Reset BMC's redfish database...")
  try:
    response = context.post(f"/redfish/v1/Managers/{manager}/Actions/Oem/AMIManager.RedfishDBReset/",
                            body={"RedfishDBResetType": "ResetAll"})
    # Wait for the BMC to reset the database
    time.sleep(60)
  except Exception as e:
    print("Failed to reset the BMC's redfish database. Continuing anyway...")
  print("Reset BMC and wait for 5mins to be reachable again...")
  try:
    response = context.post(f"/redfish/v1/Systems/{manager}/Actions/Manager.Reset",
                            body={"ResetType": "ForceRestart"})
    # Wait for the BMC to reset
    time.sleep(300)
  except Exception as e:
    print("Failed to reset the BMC. Continuing anyway...")

print("Eject virtual media, if any...")
response = context.post(
    f"/redfish/v1/Systems/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.EjectMedia", body={})
print(response.__dict__)
print(response.status)
print(response.text)
time.sleep(30)
print("Insert new virtual media...")

other_options = {}
if transfer_protocol_type == "CIFS":
  other_options = {"UserName": "root", "Password": bmc_password}

response = context.post(f"/redfish/v1/Systems/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.InsertMedia",
                        body={"Image": iso_path, "TransferProtocolType": transfer_protocol_type,
                              "Inserted": True, **other_options})

print(f"/redfish/v1/Systems/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.InsertMedia")
print({"Image": iso_path, "TransferProtocolType": transfer_protocol_type})

print(response.__dict__)
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
        print("Task is_processing: %s" % task.is_processing)
        print("Task state: %s %s" % (
            task.dict.get("TaskState"), task.dict.get("TaskState") in ("Completed", "Exception")))
        print("Task status: %s" % task.status)
        print("Task dict: %s" % task.dict)
        retry_time = task.retry_after
        time.sleep(retry_time if retry_time else 5)
    if task.status > 299:
        print()
        sys.exit(1)
    print()

EOF
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in ${bmc_address} via virtual media."
    touch /tmp/virtual_media_mount_failure
    return 1
  fi
  return 0
}

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

case "${BOOT_MODE}" in
"iso")
  echo -e "\nMounting the agent configuration ISO image in the hosts via virtual media in slot 2"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [ "${transfer_protocol_type}" == "cifs" ]; then
      IP_ADDRESS="$(dig +short "${AUX_HOST}")"
      iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}/${AGENT_CONFIGURATION_IMAGE_NAME}"
    else
      # Assuming HTTP or HTTPS
      iso_path="${transfer_protocol_type}://${AUX_HOST}/${CLUSTER_NAME}/${AGENT_CONFIGURATION_IMAGE_NAME}"
    fi
    mount_agent_configuration_image "${bmc_address}" "${redfish_user}" "${redfish_password}" \
      "${iso_path}" "${transfer_protocol_type}" &
  done

  wait
  if [ -f /tmp/virtual_media_mount_failed ]; then
    echo "Failed to mount the agent configuration ISO image in one or more hosts"
    exit 1
  fi
;;
*)
  echo "Unknown install mode: ${BOOT_MODE}"
  exit 1
esac

echo -e "\nForcing 10 minutes delay to allow instances to properly configure using configured agent image"
sleep 600