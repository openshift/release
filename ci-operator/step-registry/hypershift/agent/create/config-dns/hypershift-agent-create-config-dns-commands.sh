#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ config-dns command ************"

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$CLUSTER_NAME" > /tmp/hostedcluster_name
scp "${SSHOPTS[@]}" "/tmp/hostedcluster_name" "root@${IP}:/home/hostedcluster_name"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
MASTER_NUM=\$(oc get node -lnode-role.kubernetes.io/master="" --no-headers | wc -l)
HOSTEDCLUSTER_NAME=\$(cat /home/hostedcluster_name)
echo "address=/api.\$HOSTEDCLUSTER_NAME.ostest.test.metalkube.org/192.168.111.\$((21+\$MASTER_NUM))" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
echo "address=/api-int.\$HOSTEDCLUSTER_NAME.ostest.test.metalkube.org/192.168.111.\$((21+\$MASTER_NUM))" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf

systemctl restart NetworkManager.service
set -x
EOF
