#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  printf "%s: Stop recording \n" "$(date --utc --iso=s)"
  echo "killing resource watch"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  echo "ended oink observer gracefully"

  exit 0
}
trap cleanup EXIT


if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  . "${SHARED_DIR}/proxy-conf.sh"
fi


SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="${NAMESPACE}"

OINK_DIR=/tmp/oink

mkdir -p "${OINK_DIR}"

# $KUBECONFIG could not be available when the observer first starts
echo "waiting for $KUBECONFIG or $KUBECONFIGMINIMAL to exist"
while [[ ! -s "$KUBECONFIG" && ! -s "$KUBECONFIGMINIMAL" ]]
do
  sleep 30
done
echo "Installation started, recording Serial-over-Lan output"

# Observer pods dont support vars from external file, thus hardcoded user and host
# Additionaly, for reasons unkown to the writer, $SHARED_DIR in an observer pod works differently. The workaround is to manually copy files to a writable directory

scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/var/builds/${CLUSTER_NAME}/*.yaml" "${OINK_DIR}/"

KERNEL_PANIC_IDENTIFIER="Kernel panic"
BOOT_FAILURE_IDENTIFIER="failure reading sector" # probably caused by network errors in loading the ISO from remote share


# Search for kernel panics and boot errors
function detect_errors_on_boot(){
    local log_file="${1}"
    local bmc_address="${2}"   
    local bmc_user="${3}" 
    local bmc_pass="${4}" 
    while true ; do 
      echo "Searching for kernel panic in ${bmc_address%%.*} IPMI log..." | gawk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }'
      result=$(grep -E "${KERNEL_PANIC_IDENTIFIER}|${BOOT_FAILURE_IDENTIFIER}" "${log_file}" || true;)
      if [ "$result" ] ; then
          echo "Detected boot error in ${bmc_address%%.*}, rebooting" | gawk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }'
          echo "Boot error: $result"
          ipmitool -I lanplus -H "$bmc_address" -U "$bmc_user" -P "$bmc_pass" chassis bootdev cdrom options=efiboot
          ipmitool -I lanplus -H "$bmc_address" -U "$bmc_user" -P "$bmc_pass" power cycle
          # Use break or safely reset the content of ipmi log file to avoid infinite loop
          #break
          echo -n "" > "${log_file}"
          echo "Host was rebooted after a boot error" > "${log_file}"
      fi
      sleep 30
    done
}

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${OINK_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  IPMI_STDOUT_FILE="${ARTIFACT_DIR}/${name}_${bmc_address%%.*}_ipmi_stdout.txt"
  IPMI_STDERR_FILE="${ARTIFACT_DIR}/${name}_${bmc_address%%.*}_ipmi_stderr.txt"
  IPMI_KERNEL_FILE="${ARTIFACT_DIR}/${name}_${bmc_address%%.*}_ipmi_kp.txt"
  touch "${IPMI_STDERR_FILE}" "${IPMI_STDOUT_FILE}" "${IPMI_KERNEL_FILE}"
  echo "SoL recording on ${bmc_address}"
  sleep 3600 \
    | ipmitool -I lanplus -H "$bmc_address" -U "$bmc_user" -P "$bmc_pass" sol activate usesolkeepalive | gawk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }' \
    2>> "${IPMI_STDERR_FILE}" >> "${IPMI_STDOUT_FILE}" &
  detect_errors_on_boot "${IPMI_STDOUT_FILE}" "${bmc_address}" "${bmc_user}" "${bmc_pass}" >> "${IPMI_KERNEL_FILE}" &
done

# Keep the observer pod alive while SoL recording
sleep 3600