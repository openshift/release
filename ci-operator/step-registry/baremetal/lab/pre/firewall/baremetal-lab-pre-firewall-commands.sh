#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh DISCONNECTED=true INTERNAL_NET=192.168.90.0/24
fi

set -o errexit
set -o pipefail
set -o nounset

if [ -z "${AUX_HOST}" ]; then
    echo "AUX_HOST is not filled. Failing."
    exit 1
fi

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

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${IP_ARRAY[@]}" << 'EOF'
  set -o nounset
  set -o errexit
  IP_ARRAY=("$@")
  for ip in "${IP_ARRAY[@]}"; do
    iptables -I FORWARD -s ${ip} ! -d ${INTERNAL_NET} -j DROP
  done
EOF

