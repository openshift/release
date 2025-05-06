#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "/secret/address")

cat > /tmp/poweroff.sh << 'EOF'
echo 'Running poweroff.sh'
USER=$(curl -sSk $QUADS_INSTANCE | jq -r ".nodes[0].pm_user")
PWD=$(curl -sSk $QUADS_INSTANCE  | jq -r ".nodes[0].pm_password")
for i in $(curl -sSk $QUADS_INSTANCE | jq -r ".nodes[1:][].name"); do
  badfish -H mgmt-$i -u $USER -p $PWD --power-off
done
EOF
if [[ $LAB == "performancelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu3.labs.perfscale.redhat.com/instack/$LAB_CLOUD\_ocpinventory.json"
elif [[ $LAB == "scalelab" ]]; then
  export QUADS_INSTANCE="https://quads2.rdu2.scalelab.redhat.com/instack/$LAB_CLOUD\_ocpinventory.json"
fi
envsubst '${LAB_CLOUD},${QUADS_INSTANCE}' < /tmp/poweroff.sh > /tmp/poweroff_updated-$LAB_CLOUD.sh

scp -q ${SSH_ARGS} /tmp/poweroff_updated-$LAB_CLOUD.sh root@${bastion}:/tmp/

ssh ${SSH_ARGS} root@${bastion} "
  set -e
  set -o pipefail
  source /tmp/poweroff_updated-$LAB_CLOUD.sh
"
