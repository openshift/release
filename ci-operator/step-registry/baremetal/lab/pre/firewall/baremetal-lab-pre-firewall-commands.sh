#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

if [ "$CLUSTER_WIDE_PROXY" == "true" ] || [ "$DISCONNECTED" == "true" ]; then
 proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
 cat <<EOF > "${SHARED_DIR}/proxy-conf.sh"
 export HTTP_PROXY=${proxy}
 export HTTPS_PROXY=${proxy}
 export NO_PROXY="localhost,127.0.0.1"

 export http_proxy=${proxy}
 export https_proxy=${proxy}
 export no_proxy="localhost,127.0.0.1"
EOF
fi

if [ "${CLUSTER_WIDE_PROXY}" == "true" ]; then
  # ipi-conf-proxy will run only if a specific file is found, see step code
  cp "${CLUSTER_PROFILE_DIR}/proxy_private_url" "${SHARED_DIR}/proxy_private_url"
fi

if [ x"${DISCONNECTED}" != x"true" ]; then
  echo 'Skipping firewall configuration because no disconnected installation is requested!'
  exit
fi

declare -a IP_ARRAY
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#ip} -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  IP_ARRAY+=( "$ip" )
done

JOB="$(echo "${JOB_SPEC}" | jq '.job')"
IPI_BOOTSTRAP_IP=""

if [[ "${JOB}" =~ "baremetal-ipi" ]]; then
  echo "This is a IPI job. Saving bootstrap ip for post steps."
  cp "${SHARED_DIR}"/ipi_bootstrap_ip_address "${SHARED_DIR}"/ipi_bootstrap_ip_address_fw
  CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
  IPI_BOOTSTRAP_IP="$(<"${SHARED_DIR}/ipi_bootstrap_ip_address_fw")"

  # copy bootstrap ip to bastion host for use in cleanup
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/ipi_bootstrap_ip_address_fw" "root@${AUX_HOST}:/var/builds/$CLUSTER_NAME/"
else
  echo "This is a UPI job. Not saving bootstrap ip for post steps."
  IPI_BOOTSTRAP_IP="UPI"
fi

fw_ip=("${INTERNAL_NET_CIDR}" "${BMC_NETWORK}" "${IPI_BOOTSTRAP_IP}" "${IP_ARRAY[@]}")

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "${fw_ip[@]}" <<'EOF'
  set -o nounset
  set -o errexit
  INTERNAL_NET_CIDR="${1}"
  BMC_NETWORK="${2}"
  IPI_BOOTSTRAP_IP="${3}"
  IP_ARRAY=("${@:4}")
  for ip in "${IP_ARRAY[@]}"; do
    # TODO: change to firewalld or nftables
    iptables -A FORWARD -s ${ip} ! -d "${INTERNAL_NET_CIDR}" -j DROP
  done
  if [[ "${IPI_BOOTSTRAP_IP}" != "UPI" ]]; then
    iptables -A FORWARD -s "${IPI_BOOTSTRAP_IP}" -d "${BMC_NETWORK}" -j ACCEPT
    iptables -A FORWARD -s "${IPI_BOOTSTRAP_IP}" ! -d "${INTERNAL_NET_CIDR}" -j DROP
  fi
EOF

# mirror-images-by-oc-adm will run only if a specific file is found, see step code
cp "${CLUSTER_PROFILE_DIR}/mirror_registry_url" "${SHARED_DIR}/mirror_registry_url"

