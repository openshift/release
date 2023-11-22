#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

function mount_virtual_media() {
  ### Sushy doesn't support NFS as TransferProtcolType, and some servers' BMCs (in particular the ones of the arm64 servers)
  ##  are not 100% compliant with the Redfish standard. Therefore, relying on the raw redfish python library.
  local bmc_address="${1}"
  local bmc_username="${2}"
  local bmc_password="${3}"
  local iso_path="${4}"
  local transfer_protocol_type="${5}"
  echo "Downloading python script"
  curl curl https://github.com/bmanzari/release/blob/templating_test/ci-operator/step-registry/baremetal/lab/agent/misc/scripts/mount_virtual_media.py > "${SHARED_DIR}/mount_virtual_media.py"
  echo "Mounting the ISO image in ${bmc_address} via virtual media..."
  python3 -u - "${bmc_address}" "${bmc_username}" "${bmc_password}" \
    "${iso_path}" "${transfer_protocol_type^^}" "${SHARED_DIR}/mount_virtual_media.py"

  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in ${bmc_address} via virtual media."
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


function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}