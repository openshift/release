#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing.";  exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

if [ "${SELF_MANAGED_NETWORK}" != "true" ]; then
  echo "Skipping rollback for the DHCP/PXE/GRUB2 configuration."
  exit 0
fi

# Retrieves the MACs of the hosts to delete their grub.cfg
declare -a MAC_ARRAY
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ "${#mac}" -eq 0 ]; then
    echo "Unable to parse an entry in the hosts.yaml file"
  fi
  MAC_ARRAY+=( "$mac" )
done

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "${MAC_ARRAY[@]}" << 'EOF'
  set -o nounset
  NAMESPACE="${1}"; shift
  MAC_ARRAY=("$@")
  echo "Removing the DHCP/PXE config..."
  sed -i "/; BEGIN ${NAMESPACE}/,/; END ${NAMESPACE}$/d" /opt/dhcpd/root/etc/dnsmasq.conf
  docker restart dhcpd
  echo "Removing the grub config..."
  for mac in "${MAC_ARRAY[@]}"; do
    rm -f "/opt/tftpboot/grub.cfg-01-$(echo "$mac" | tr ':' '-')" || echo "no grub.cfg for $mac."
  done
EOF
