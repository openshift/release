#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
target_bastion=$(cat ${CLUSTER_PROFILE_DIR}/bastion)

# Check if target bastion is in maintenance mode
if ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p root@${bastion}" root@${target_bastion} 'test -f /root/pause'; then
  echo "The cluster is on maintenance mode. Remove the file /root/pause in the bastion host when the maintenance is over"
  exit 1
fi

LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
export LAB_CLOUD
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE

cat > /tmp/poweroff.sh << 'EOF'
echo 'Running poweroff.sh'
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
USER=$(curl -sSk $OCPINV | jq -r ".nodes[0].pm_user")
PWD=$(curl -sSk $OCPINV  | jq -r ".nodes[0].pm_password")
for i in $(curl -sSk $OCPINV | jq -r ".nodes[1:][].name"); do
   podman run quay.io/quads/badfish:latest -H mgmt-$i -u $USER -p $PWD --power-off
done
EOF
envsubst '${LAB_CLOUD},${QUADS_INSTANCE}' < /tmp/poweroff.sh > /tmp/poweroff_updated-$LAB_CLOUD.sh

scp -q ${SSH_ARGS} /tmp/poweroff_updated-$LAB_CLOUD.sh root@${bastion}:/tmp/

ssh ${SSH_ARGS} root@${bastion} "
  set -e
  set -o pipefail
  source /tmp/poweroff_updated-$LAB_CLOUD.sh
"
