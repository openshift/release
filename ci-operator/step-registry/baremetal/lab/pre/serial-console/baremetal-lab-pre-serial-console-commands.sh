#!/bin/bash

# OVE automation requires setting serial console parameters to certain values
# See https://docs.google.com/presentation/d/1d3heMS5JAFmubJpW_8YuHa5r3AlCvj2tW0akQ6b8EQw/edit?usp=sharing

HOST_ADDRESS=$(<"${SHARED_DIR}"/cluster_name).$(<"${CLUSTER_PROFILE_DIR}"/base_domain)
HOST_ID=$(yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml")

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  -p $((14000+"${HOST_ID}")))

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do

  bmc_user=$(echo "$bmhost" | jq -r '.bmc_user')
  bmc_pass=$(echo "$bmhost" | jq -r '.bmc_pass')
  bmc_address=$(echo "$bmhost" | jq -r '.bmc_address')
  vendor=$(echo "$bmhost" | jq -r '.vendor')

  timeout -s 9 15m ssh "${SSHOPTS[@]}" root@access."${HOST_ADDRESS}" prepare_host_for_boot \
  --host "$bmc_address" \
  --user "$bmc_user" \
  --password "$bmc_pass" \
  --vendor "$vendor" \
  --sol "true"
done
