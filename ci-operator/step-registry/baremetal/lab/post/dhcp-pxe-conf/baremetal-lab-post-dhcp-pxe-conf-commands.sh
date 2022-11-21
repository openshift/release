#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh SELF_MANAGED_NETWORK=true
fi

set -o errexit
set -o pipefail
set -o nounset

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
  MAC_ARRAY+=( "$mac" )
done

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "${MAC_ARRAY[@]}" << 'EOF'
  set -o nounset
  set -o errexit
  set -o pipefail
  NAMESPACE="${1}"; shift
  MAC_ARRAY=("$@")
  echo "Removing the DHCP/PXE config..."
  sed -i "/; BEGIN ${NAMESPACE}/,/; END ${NAMESPACE}$/d" /opt/dhcpd/root/etc/dnsmasq.conf
  echo "Removing the grub config..."
  for mac in "${MAC_ARRAY[@]}"; do
    rm -f "/opt/tftpboot/grub.cfg-01-$(echo "$mac" | tr ':' '-')" || echo "no grub.cfg for $mac."
  done
EOF
