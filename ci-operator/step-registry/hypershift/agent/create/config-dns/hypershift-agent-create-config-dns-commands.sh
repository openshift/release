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
WORKER_IP=\$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
BASEDOMAIN=\$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
HOSTEDCLUSTER_NAME=\$(cat /home/hostedcluster_name)
echo "address=/api.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
echo "address=/api-int.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
echo "address=/.apps.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
systemctl restart NetworkManager.service

virsh net-dumpxml ostestbm > /tmp/ostestbm.xml
sed -i 's/<dns>/<dns>\n    <forwarder domain='"'"\$BASEDOMAIN"'"' addr='"'"'127.0.0.1'"'"'\/>/' /tmp/ostestbm.xml
virsh net-define /tmp/ostestbm.xml
virsh net-destroy ostestbm;virsh net-start ostestbm
systemctl restart libvirtd.service
set -x
EOF
