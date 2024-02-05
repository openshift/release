#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ "${ADDITIONAL_WORKERS}" == "0" ]; then
    echo "No additional workers requested"
    exit 0
fi

if [ "${ADDITIONAL_WORKERS_DAY2}" != "true" ]; then
    echo "Skipping as the additional nodes have been provisioned at installation time."
    exit 0
fi

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

if [[ "${CLUSTER_TYPE}" == *ocp-metal* ]]; then
  SSHOPTS=(-o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key")
  AUX_HOST="$(<"${CLUSTER_PROFILE_DIR}"/aux-host)"
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function approve_csrs() {
  while [[ ! -f '/tmp/scale-out-complete' ]]; do
    sleep 30
    echo "approve_csrs() running..."
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
      | xargs --no-run-if-empty oc adm certificate approve || true
  done
}

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
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
    ready_nodes=$(get_ready_nodes_count)
    if [ x"${ready_nodes}" == x"${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

## Valid for baremetal hosts only
function wait_for_power_down_and_release() {
  local bmc_address="${1}"
  local bmc_user="${2}"
  local bmc_pass="${3}"
  local bmc_forwarded_port="${4}"
  local vendor="${5}"
  local ipxe_via_vmedia="${6}"
  sleep 90
  local retry_max=40 # 15*40=600 (10 min)
  while [ $retry_max -gt 0 ] && ! ipmitool -I lanplus -H "$AUX_HOST" -p "$bmc_forwarded_port" \
    -U "$bmc_user" -P "$bmc_pass" power status | grep -q "Power is off"; do
    echo "$bmc_address is not powered off yet... waiting"
    sleep 30
    retry_max=$(( retry_max - 1 ))
  done
  if [ $retry_max -le 0 ]; then
    echo -n "$bmc_address didn't power off successfully..."
    if [ -f "/tmp/$bmc_address" ]; then
      echo "$bmc_address kept powered on and needs further manual investigation..."
      return 1
    else
      # We perform the reboot at most twice to overcome some known BMC hardware failures
      # that sometimes keep the hosts frozen before POST.
      echo "retrying $bmc_address again to reboot..."
      touch "/tmp/$bmc_address"
      host="${bmc_forwarded_port##1[0-9]}"
      timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe"
      wait_for_power_down_and_release "$bmc_address" "$bmc_user" "$bmc_pass" "$bmc_forwarded_port" "$vendor" "$ipxe_via_vmedia"
      return $?
    fi
  fi
  echo "$bmc_address is now powered off. Releasing the node."

  yq --inplace "del(.[]|select(.bmc_address|test(\"${bmc_address}\")))" "$SHARED_DIR/hosts.yaml"
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
          "${CLUSTER_NAME}" "${bmc_address}" << 'EOF'
    BUILD_USER=ci-op
    CLUSTER_NAME="$1"
    BMC_ADDRESS="$2"
    LOCK="/tmp/reserved_file.lock"
    LOCK_FD=200
    touch $LOCK
    exec 200>$LOCK

    set -e
    trap catch_exit ERR INT

    function catch_exit {
      echo "Error. Releasing lock $LOCK_FD ($LOCK)"
      flock -u $LOCK_FD
      exit 1
    }

    echo "Acquiring lock $LOCK_FD ($LOCK) (waiting up to 10 minutes)"
    flock -w 600 $LOCK_FD
    echo "Lock acquired $LOCK_FD ($LOCK)"

    sed -i "/${BMC_ADDRESS}.*,${CLUSTER_NAME},${BUILD_USER},/d" /etc/hosts_pool_reserved
    sed -i "/${BMC_ADDRESS}.*,${CLUSTER_NAME},${BUILD_USER},/d" /etc/vips_reserved

    echo "Releasing lock $LOCK_FD ($LOCK)"
    flock -u $LOCK_FD
EOF
  return 0
}

EXPECTED_NODES=$(( $(get_ready_nodes_count) + ADDITIONAL_WORKERS ))

echo "Cluster type is ${CLUSTER_TYPE}"

case "$CLUSTER_TYPE" in
*ocp-metal*)
  # Extract the ignition file for additional workers if additional workers count > 0
  oc extract -n openshift-machine-api secret/worker-user-data-managed --keys=userData --to=- > "${SHARED_DIR}"/worker.ign
  echo -e "\nCopying ignition files into bastion host..."
  chmod 644 "${SHARED_DIR}"/*.ign
  scp "${SSHOPTS[@]}" "${SHARED_DIR}"/*.ign "root@${AUX_HOST}:/opt/html/${CLUSTER_NAME}/"

  # For Bare metal UPI clusters, we consider the reservation of the nodes, and the configuration of the boot done
  # by the baremetal-lab-pre-* steps.
  # Therefore, we only need to power on the nodes and wait for them to join the cluster.
  #
  echo -e "\nPower on the hosts..."
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[] | select(.name|test("-a-"))' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    if [ ${#bmc_address} -eq 0 ] || [ ${#bmc_user} -eq 0 ] || [ ${#bmc_pass} -eq 0 ]; then
      echo "Error while unmarshalling hosts entries"
      exit 1
    fi
    echo "Power on ${bmc_address//.*/} (${name})..."
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe" &
  done
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

echo "Wait for the nodes to become ready..."
approve_csrs &
wait_for_nodes_readiness ${EXPECTED_NODES}
ret="$?"
if [ "${ret}" != "0" ]; then
  echo "Some errors occurred, exiting with ${ret}."
  exit "${ret}"
fi
# let the approve_csr function finish
touch /tmp/scale-out-complete
if [ -z "${SCALE_IN_ARCHITECTURES}" ]; then
  echo "No scale-in architectures specified. Continuing..."
  exit 0
fi

# $SCALE_IN_ARCHITECTURES is a non-zero length comma-separated list of architectures to scale in.
case "$CLUSTER_TYPE" in
*ocp-metal*)
  # For baremetal UPI clusters, we need to iterate through the architectures,
  # remove the grub.cfg file for the hosts that are not needed anymore, and reset them to wipe the disks.
  # Finally, we need to remove the hosts from the reservation.
  removal_list=( )
  echo "Removing the hosts having architectures: ${SCALE_IN_ARCHITECTURES}..."
  REGEX=$(echo "$SCALE_IN_ARCHITECTURES" | tr ',' '|')
  for bmhost in $(yq e -o=j -I=0 ".[] | select(.arch|test(\"${REGEX}\") and .name|test(\"worker\"))" "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    removal_list+=( "${name}/${mac}" )
    oc adm cordon "${name}.${CLUSTER_NAME}.${BASE_DOMAIN}"
    oc adm drain --force --ignore-daemonsets --delete-local-data --grace-period=10 "${name}.${CLUSTER_NAME}.${BASE_DOMAIN}"
    oc delete node "${name}.${CLUSTER_NAME}.${BASE_DOMAIN}"
  done
  echo "${removal_list[@]}"
  # Remove the grub.cfg file to make sure the host will wipe its disk in the next boot.
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "${CLUSTER_NAME}" "${removal_list[@]}" << 'EOF'
    CLUSTER_NAME="${1}"
    for host in "${@:2}"; do
      mac="${host##*/}"
      name="${host%%/*}"
      echo "Removing the grub.cfg file for host with mac ${mac}..."
      rm -f "/opt/tftpboot/grub.cfg-01-${mac//:/-}" || echo "no grub.cfg for $mac."
      echo "Removing the DHCP config for ${name}/${mac}..."
      sed -i "/^dhcp-host=$mac/d" /opt/dnsmasq/etc/dnsmasq.conf
      echo "Removing the DNS config for ${name}/${mac}..."
      sed -i "/${name}.*${CLUSTER_NAME:-glob-protected-from-empty-var}/d" /opt/bind9_zones/{zone,internal_zone.rev}
      # haproxy.cfg is mounted as a volume, and we need to remove the bootstrap node from being a backup:
      # using sed -i leads to creating a new file with a different inode number.
      # A different inode means that the file mapping mounted from the host to the container gets lost.
      # Re-writing with cat (+ redirection) the desired haproxy.cfg doesn't lead to a
      # new file and inode allocation.
      # See https://github.com/moby/moby/issues/15793
      F="/var/builds/${CLUSTER_NAME}/haproxy/haproxy.cfg"
      sed "/server ${name}/d" "${F}" > "${F}.tmp"
      cat "${F}.tmp" > "${F}"
      rm -rf "${F}.tmp"
      docker kill -s HUP "haproxy-${CLUSTER_NAME}"
      podman exec bind9 rndc reload
      podman exec bind9 rndc flush
      systemctl restart dhcp
    done
EOF
  echo "Wiping the disks and releasing the nodes for further reservations in other jobs..."

  for bmhost in $(yq e -o=j -I=0 ".[] | select(.arch|test(\"${REGEX}\") and .name|test(\"worker-\"))" "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "pxe" &
    (if ! wait_for_power_down_and_release "$bmc_address" "$bmc_user" "$bmc_pass" "$bmc_forwarded_port" "$vendor" "$ipxe_via_vmedia" \
      "$vendor" "$ipxe_via_vmedia"; then
      echo "$bmc_address" >> /tmp/failed
    fi) &
  done
  wait
  echo "All children terminated."

  if [ -s /tmp/failed ]; then
    echo The following nodes failed to power off:
    cat /tmp/failed
    # Do not exit with an error code here as the power off is not a critical step and might fail
    # due to BMC issues.
  fi
;;
*)
  echo "Scaling in by architecture for the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

exit 0
