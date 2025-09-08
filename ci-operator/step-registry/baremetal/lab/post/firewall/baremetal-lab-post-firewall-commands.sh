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
  echo "This is a IPI job. Remove firewall rule for bootstrap IP."
  IPI_BOOTSTRAP_IP="$(<"${SHARED_DIR}/ipi_bootstrap_ip_address_fw")"
else
  echo "This is a UPI job. Firewall rule is already removed for bootstrap IP."
  IPI_BOOTSTRAP_IP="UPI"
fi

fw_ip=("${INTERNAL_NET_CIDR}" "${BMC_NETWORK}" "${IPI_BOOTSTRAP_IP}" "${IP_ARRAY[@]}")

echo 'Deprovisioning firewall configuration'
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "${fw_ip[@]}" <<'EOF'
  set -o nounset
  set -o errexit
  INTERNAL_NET_CIDR="${1}"
  BMC_NETWORK="${2}"
  IPI_BOOTSTRAP_IP="${3}"
  IP_ARRAY=("${@:4}")
  for ip in "${IP_ARRAY[@]}"; do
    # TODO: change to firewalld or nftables
    while read -r line; do
      read -r -a RULE <<< "${line}"
      [[ "${line}" =~ D.*s.*${ip}.*j ]] && iptables "${RULE[@]}"
    done < <(iptables -S FORWARD | grep "${ip}" | sed 's/^-A /-D /')
  done
  if [[ "${IPI_BOOTSTRAP_IP}" != "UPI" ]]; then
    while read -r line; do
      read -r -a RULE <<< "${line}"
      [[ "${line}" =~ D.*s.*${IPI_BOOTSTRAP_IP}.*j ]] && iptables "${RULE[@]}"
    done < <(iptables -S FORWARD | grep "${IPI_BOOTSTRAP_IP}" | sed 's/^-A /-D /')
  fi
EOF
