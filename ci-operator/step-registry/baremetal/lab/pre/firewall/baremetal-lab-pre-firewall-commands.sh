#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

set -x

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

if [ x"${DISCONNECTED}" != x"true" ]; then
  echo 'Skipping firewall configuration'
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

echo "${IP_ARRAY[@]}"

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${INTERNAL_NET_CIDR}" "${IP_ARRAY[@]}"  << 'EOF'
  set -o nounset
  set -o errexit
  set -x
  INTERNAL_NET_CIDR="${1}"
  IP_ARRAY="${@:2}"
  for ip in $IP_ARRAY; do
    iptables -I FORWARD -s ${ip} ! -d "${INTERNAL_NET_CIDR}" -j DROP
  done
EOF

# mirror-images-by-oc-adm will run if a specific file is found, see code below

# private mirror registry host
# <public_dns>:<port>
# MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
# if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
#     echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
#     exit 1
# fi
MIRROR_REGISTRY_URL="${AUX_HOST}:5000"
echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"
