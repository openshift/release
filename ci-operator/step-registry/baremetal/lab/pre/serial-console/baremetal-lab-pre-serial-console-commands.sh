#!/bin/bash

# OVE automation requires setting serial console parameters to certain values
# See https://docs.google.com/presentation/d/1d3heMS5JAFmubJpW_8YuHa5r3AlCvj2tW0akQ6b8EQw/edit?usp=sharing

CONTAINER_NAME="haproxy-$(<"${SHARED_DIR}"/cluster_name)"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do

  bmc_user=$(echo "$bmhost" | jq -r '.bmc_user')
  bmc_pass=$(echo "$bmhost" | jq -r '.bmc_pass')
  bmc_address=$(echo "$bmhost" | jq -r '.bmc_address')
  vendor=$(echo "$bmhost" | jq -r '.vendor')

  timeout -s 9 15m ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
  "nsenter -n -t \"\$(podman inspect -f '{{ .State.Pid }}' \"${CONTAINER_NAME}\")\" \
   ssh -o StrictHostKeyChecking=no root@\"${OVE_ISO_STORAGE_HOST}\" prepare_host_for_boot \
  --host \"${bmc_address}\" \
  --user \"${bmc_user}\" \
  --password \"${bmc_pass}\" \
  --vendor \"${vendor}\" \
  --iso \"true\""
done
