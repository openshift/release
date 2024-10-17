#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

bastion=$(cat "/secret/address")

# 1. Set the corresponding host on the lab Foreman instance
# 2. Use badfish to set the boot interface and bounce the box
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} '
  USER=$(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD | jq -r ".nodes[0].pm_user")
  PWD=$(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD | jq -r ".nodes[0].pm_password")
  for i in $(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))] .[].name"); do
    hammer host update --name $i --operatingsystem $FOREMAN_OS -pxe-loader "Grub2 UEFI" --build 1
    sleep 10
    badfish -H $i -u $USER -p $PWD -i ~/badfish_interfaces.yml -t foreman
  done'

# Wait until the newly deployed servers are accessible via ssh
sleep 300
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} '
  for i in $(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))] .[].name"); do
    nc -z $i 22
    while [ $? -ne 0 ]; do
      fc -e : -1
      echo "Trying SSH port on host $i ..."
      sleep 60
    done
  done'