#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "/secret/address")

# 1. Set the corresponding host on the lab Foreman instance
# 2. Use badfish to set the boot interface and bounce the box
cat > /tmp/foreman-deploy.sh << 'EOF'
echo 'Running foreman-deploy.sh'
USER=$(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r ".nodes[0].pm_user")
PWD=$(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r ".nodes[0].pm_password")
for i in $(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  hammer host update --name $i --operatingsystem $FOREMAN_OS -pxe-loader "Grub2 UEFI" --build 1
  sleep 10
  badfish -H $i -u $USER -p $PWD -i ~/badfish_interfaces.yml -t foreman
done
EOF
if [[ $LAB == "performancelab" ]]; then
  export QUADS_INSTANCE="http://quads.rdu3.labs.perfscale.redhat.com"
elif [[ $LAB == "scalelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu2.scalelab.redhat.com"
fi
envsubst '${FOREMAN_OS},${LAB_CLOUD},${NUM_NODES},${QUADS_INSTANCE},${STARTING_NODE}' < /tmp/foreman-deploy.sh > /tmp/foreman-deploy_updated.sh

# Wait until the newly deployed servers are accessible via ssh
cat > /tmp/foreman-wait.sh << 'EOF'
echo 'Running foreman-wait.sh'
for i in $(curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  nc -z $i 22
  while [ $? -ne 0 ]; do
    fc -e : -1
    echo "Trying SSH port on host $i ..."
    sleep 60
  done
done
EOF
envsubst '${LAB_CLOUD},${NUM_NODES},${QUADS_INSTANCE},${STARTING_NODE}' < /tmp/foreman-wait.sh > /tmp/foreman-wait_updated.sh

scp -q ${SSH_ARGS} /tmp/foreman-deploy_updated.sh root@${bastion}:/tmp/
scp -q ${SSH_ARGS} /tmp/foreman-wait_updated.sh root@${bastion}:/tmp/

ssh ${SSH_ARGS} root@${bastion} "
  set -e
  set -o pipefail
  curl -sS $QUADS_INSTANCE/cloud/$LAB_CLOUD\_ocpinventory.json | jq -r '.nodes[0].name' > /tmp/foreman_inventory_$LAB_CLOUD
  ansible -i /tmp/foreman_inventory_$LAB_CLOUD all -m script -a /tmp/foreman-deploy_updated.sh
  sleep 300
  ansible -i /tmp/foreman_inventory_$LAB_CLOUD all -m script -a /tmp/foreman-wait_updated.sh
"