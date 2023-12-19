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

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

function mount_virtual_media() {
  local host="${1}"
  local iso_path="${2}"
  echo "Mounting the ISO image in #${host} via virtual media..."
  # Mount the unconfigured agent ISO image in first Virtual Media Slot (0, default)
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

function reset_host() {
  # bmc_address is used for redfish, via proxy
  # bmc_forwarded_port is used for ipmitool
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  local bmc_forwarded_port="${4}"
  local vendor="${5}"
  local ipxe_via_vmedia="${6}"
  local host="${bmc_forwarded_port##1[0-9]}"
  host="${host##0}"
  echo "Resetting the host #${host}..."
  case "${vendor}" in
    ampere)
      boot_selection=$([ "${BOOT_MODE}" == "pxe" ] && echo force_pxe || echo force_cdrom)
      ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_forwarded_port}" \
        -U "$bmc_user" -P "$bmc_pass" \
        chassis bootparam set bootflag "$boot_selection" options=PEF,watchdog,reset,power
    ;;
    dell)
      # this is how sushy does it
      boot_selection=$([ "${BOOT_MODE}" == "pxe" ] && [ "${ipxe_via_vmedia}" != "true" ] && echo PXE || echo VCD-DVD)
      curl -x "${proxy}" -k -u "${bmc_user}:${bmc_pass}" -X POST \
        "https://$bmc_address/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Oem/EID_674_Manager.ImportSystemConfiguration" \
         -H "Content-Type: application/json" -d \
         '{"ShareParameters":{"Target":"ALL"},"ImportBuffer":
            "<SystemConfiguration><Component FQDD=\"iDRAC.Embedded.1\">
            <Attribute Name=\"ServerBoot.1#BootOnce\">Enabled</Attribute>
            <Attribute Name=\"ServerBoot.1#FirstBootDevice\">'"$boot_selection"'</Attribute>
            </Component></SystemConfiguration>"}'
    ;;
    hpe)
      boot_selection=$([ "${BOOT_MODE}" == "pxe" ] && [ "${ipxe_via_vmedia}" != "true" ] && echo Pxe || echo Cd)
      curl -x "${proxy}" -k -u "${bmc_user}:${bmc_pass}" -X PATCH \
        "https://$bmc_address/redfish/v1/Systems/1/" \
        -H 'Content-Type:application/json' \
        -d '{"Boot": {"BootSourceOverrideTarget": "'"$boot_selection"'"}'
    ;;
    *)
      echo "Unknown vendor ${vendor}"
      return 1
  esac
  ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_forwarded_port}" \
    -U "$bmc_user" -P "$bmc_pass" \
    power off || echo "Already off"
  # If the host is not already powered off, the power on command can fail while the host is still powering off.
  # Let's retry the power on command multiple times to make sure the command is received in the correct state.
  for i in {1..10} max; do
    if [ "$i" == "max" ]; then
      echo "Failed to reset #$host"
      return 1
    fi
    ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_forwarded_port}" \
      -U "$bmc_user" -P "$bmc_pass" \
      power on && break
    echo "Failed to power on #$host, retrying..."
    sleep 5
  done
}

# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

case "${BOOT_MODE}" in
"iso")
  echo -e "\nMounting the unconfigured agent ISO image in the hosts via virtual media and powering on the hosts..."
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [ "${transfer_protocol_type}" == "cifs" ]; then
      IP_ADDRESS="$(dig +short "${AUX_HOST}")"
      iso_path="${IP_ADDRESS}/isos/${CLUSTER_NAME}/${UNCONFIGURED_AGENT_IMAGE_FILENAME}"
    else
      # Assuming HTTP or HTTPS
      iso_path="${transfer_protocol_type:-http}://${AUX_HOST}/${CLUSTER_NAME}/${UNCONFIGURED_AGENT_IMAGE_FILENAME}"
    fi
    mount_virtual_media "${host}" "${iso_path}" &
  done

  wait
  if [ -f /tmp/virtual_media_mount_failed ]; then
    echo "Failed to mount unconfigured agent the ISO image in one or more hosts"
    exit 1
  fi
;;
*)
  echo "Unknown install mode: ${BOOT_MODE}"
  exit 1
esac
proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "Power on ${host} (${name})..."
  reset_host "${bmc_address}" "${bmc_user}" "${bmc_pass}" "${bmc_forwarded_port}" "${vendor}" "${ipxe_via_vmedia}" &
done
wait
echo -e "\nForcing 10 minutes delay to allow instances to properly boot up"
sleep 600
