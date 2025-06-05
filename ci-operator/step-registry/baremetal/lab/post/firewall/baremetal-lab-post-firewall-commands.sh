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
    test -f /var/builds/${NAMESPACE}/preserve && \
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

echo 'Deprovisioning firewall configuration'
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${INTERNAL_NET_CIDR}" "${IP_ARRAY[@]}" << 'EOF'
  set -o nounset
  set -o errexit
  INTERNAL_NET_CIDR="${1}"
  IP_ARRAY="${@:2}"
  for ip in $IP_ARRAY; do
    iptables -D FORWARD -s ${ip} ! -d "${INTERNAL_NET_CIDR}" -j DROP
  done
EOF