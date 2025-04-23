#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

[ -z "${PULL_NUMBER:-}" ] && \
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    test -f /var/builds/"${NAMESPACE}"/preserve && \
  exit 0

if [ x"${DISCONNECTED}" != x"true" ]; then
  echo 'Skipping firewall configuration deprovisioning as not in a disconnected environment'
  exit 0
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

IPI_BOOTSTRAP_IP=""

if [[ -f "${SHARED_DIR}/ipi_bootstrap_ip_address_fw" ]]; then
  IPI_BOOTSTRAP_IP="$(<"${SHARED_DIR}/ipi_bootstrap_ip_address_fw")"
fi

echo 'Deprovisioning firewall configuration'
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${INTERNAL_NET_CIDR}" "${BMC_NETWORK}" "${IPI_BOOTSTRAP_IP}" "${IP_ARRAY[@]}" << 'EOF'
  set -o nounset
  set -o errexit
  INTERNAL_NET_CIDR="${1}"
  BMC_NETWORK="${2}"
  IPI_BOOTSTRAP_IP="${3}"
  IP_ARRAY=("${@:4}")
  for ip in "${IP_ARRAY[@]}"; do
    # TODO: change to firewalld or nftables
    iptables -D FORWARD -s "${ip}" ! -d "${INTERNAL_NET_CIDR}" -j DROP
    rule=$(iptables -S FORWARD | grep "${ip}"| grep "${BMC_NETWORK}" | grep ACCEPT | sed 's/^-A /-D /')
    [[ -n "${rule}" ]] && read -r -a RULE <<< "${rule}"
    [[ "${rule}" =~ D.*$ip.*ACCEPT ]] && iptables "${RULE[@]}"
  done
  if [[ -n "${IPI_BOOTSTRAP_IP}" ]]; then
    rule=$(iptables -S FORWARD | grep "${IPI_BOOTSTRAP_IP}"| grep DROP | sed 's/^-A /-D /')
    read -r -a RULE <<< "${rule}"
    [[ "${rule}" =~ D.*$IPI_BOOTSTRAP_IP.*DROP ]] && iptables "${RULE[@]}"
    while read -r line; do
      read -r -a RULE <<< "${line}"
      [[ "${line}" =~ D.*$IPI_BOOTSTRAP_IP.*ACCEPT ]] && iptables "${RULE[@]}"
    done < <(iptables -S FORWARD | grep "${IPI_BOOTSTRAP_IP}"| grep ACCEPT | sed 's/^-A /-D /')
  fi
EOF
