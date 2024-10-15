#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

bastion=$(cat "/secret/address")

# Set the corresponding host on the lab Foreman instance
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} '
  NUM_NODES_CLOUD=$(curl -sS http://$QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | grep name | wc -l)
  for i in $(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | grep name | tail -n $((NUM_NODES_CLOUD-STARTING_NODE)) | head -n $NUM_NODES | jq ".nodes[].name"); do
    echo $i
    hammer host update --name $i --operatingsystem $FOREMAN_OS -pxe-loader "Grub2 UEFI" --build 1
  done'

# Use badfish to set the boot interface and bounce the box
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "
  echo TODO"

# Wait until the newly deployed servers are accessible via ssh
# TODO