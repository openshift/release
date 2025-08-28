#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
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
