#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
export LAB_CLOUD
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE

# 1. Set the corresponding host on the lab Foreman instance
# 2. Use badfish to set the boot interface and bounce the box
cat > /tmp/foreman-deploy.sh << 'EOF'
echo 'Running foreman-deploy.sh'
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
USER=$(curl -sSk $OCPINV | jq -r ".nodes[0].pm_user")
PSWD=$(curl -sSk $OCPINV  | jq -r ".nodes[0].pm_password")
for i in $(curl -sSk $OCPINV | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  hammer --verify-ssl false -u $LAB_CLOUD -p $PSWD host update --name $i --operatingsystem "$FOREMAN_OS" --pxe-loader "Grub2 UEFI" --build 1
  sleep 10
  podman run quay.io/quads/badfish:latest --reboot-only -H mgmt-$i -u $USER -p $PSWD
done
EOF
envsubst '${FOREMAN_OS},${LAB_CLOUD},${NUM_NODES},${QUADS_INSTANCE},${STARTING_NODE}' < /tmp/foreman-deploy.sh > /tmp/foreman-deploy_updated-$LAB_CLOUD.sh

# Wait until the newly deployed servers are accessible via ssh
cat > /tmp/foreman-wait.sh << 'EOF'
echo 'Running foreman-wait.sh'
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
for i in $(curl -sSk $OCPINV | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  while ! nc -z $i 22; do
    echo "Trying SSH port on host $i ..."
    sleep 60
  done
done
EOF
envsubst '${NUM_NODES},${QUADS_INSTANCE},${STARTING_NODE}' < /tmp/foreman-wait.sh > /tmp/foreman-wait_updated-$LAB_CLOUD.sh

scp -q ${SSH_ARGS} /tmp/foreman-deploy_updated-$LAB_CLOUD.sh root@${bastion}:/tmp/
scp -q ${SSH_ARGS} /tmp/foreman-wait_updated-$LAB_CLOUD.sh root@${bastion}:/tmp/

ssh ${SSH_ARGS} root@${bastion} "
  set -e
  set -o pipefail
  source /tmp/foreman-deploy_updated-$LAB_CLOUD.sh
  sleep 300
  source /tmp/foreman-wait_updated-$LAB_CLOUD.sh
"