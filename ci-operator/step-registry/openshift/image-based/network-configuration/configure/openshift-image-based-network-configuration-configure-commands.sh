#!/bin/bash
set -euo pipefail

echo "************ openshift image based network configuration configure commands ************"

# shellcheck disable=SC2154
trap 'rc=$?; if [ $rc -ne 0 ]; then echo "ERROR: Step failed at line $LINENO with exit code $rc"; fi' EXIT

ssh_retry() {
  local retries=3 delay=10
  for ((i=1; i<=retries; i++)); do
    if "$@"; then return 0; fi
    if ((i < retries)); then
      echo "Attempt $i/$retries failed, retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2))
    else
      echo "Attempt $i/$retries failed"
    fi
  done
  echo "All $retries attempts failed"
  return 1
}

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

# Validate IP_STACK value
case "${IP_STACK}" in
  v4|v4v6|v6v4) ;;
  *) echo "ERROR: Unsupported IP_STACK value '${IP_STACK}'. Must be v4, v4v6, or v6v4"; exit 1 ;;
esac

# Validate IPv6 parameters for dual-stack modes
if [[ "${IP_STACK}" == "v4v6" || "${IP_STACK}" == "v6v4" ]]; then
  if [[ -z "${IPC_IPV6_ADDRESS}" || -z "${IPC_IPV6_MACHINE_NETWORK}" || -z "${IPC_IPV6_GATEWAY}" ]]; then
    echo "ERROR: IP_STACK=${IP_STACK} requires IPC_IPV6_ADDRESS, IPC_IPV6_MACHINE_NETWORK, and IPC_IPV6_GATEWAY to be set"
    exit 1
  fi
  echo "Dual-stack mode (${IP_STACK}): IPv6 address=${IPC_IPV6_ADDRESS}, network=${IPC_IPV6_MACHINE_NETWORK}, gateway=${IPC_IPV6_GATEWAY}"
fi

cat <<EOF > ${SHARED_DIR}/network-configuration.sh
#!/bin/bash
set -xeuo pipefail

cd ${remote_workdir}/ib-orchestrate-vm

# the IBI installed cluster use IPv4 192.168.127.74/24 and IPv6 fd00:127::74/64
make ipc \
  IP_STACK=${IP_STACK} \
  IPC_IPV4_ADDRESS=${IPC_IPV4_ADDRESS} \
  IPC_IPV4_MACHINE_NETWORK=${IPC_IPV4_MACHINE_NETWORK} \
  IPC_IPV4_GATEWAY=${IPC_IPV4_GATEWAY} \
  IPC_IPV6_ADDRESS=${IPC_IPV6_ADDRESS} \
  IPC_IPV6_MACHINE_NETWORK=${IPC_IPV6_MACHINE_NETWORK} \
  IPC_IPV6_GATEWAY=${IPC_IPV6_GATEWAY} \
  IPC_DNS_SERVERS=${IPC_DNS_SERVERS} \
  IPC_CLUSTER_NAME=${IPC_CLUSTER_NAME} \
  IBI_VM_NAME=${IBI_VM_NAME}

EOF

chmod +x ${SHARED_DIR}/network-configuration.sh

echo "Transferring network configuration script..."
ssh_retry scp "${SSHOPTS[@]}" "${SHARED_DIR}/network-configuration.sh" "${ssh_host_ip}:${remote_workdir}"

echo "Configure network configuration..."
ssh "${SSHOPTS[@]}" "${ssh_host_ip}" "${remote_workdir}/network-configuration.sh"
