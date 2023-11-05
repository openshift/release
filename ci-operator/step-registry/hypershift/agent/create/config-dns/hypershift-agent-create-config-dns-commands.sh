#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ config-dns command ************"

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$CLUSTER_NAME" > /tmp/hostedcluster_name
scp "${SSHOPTS[@]}" "/tmp/hostedcluster_name" "root@${IP}:/home/hostedcluster_name"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -x
WORKER_IPS=\$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
BASEDOMAIN=\$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
HOSTEDCLUSTER_NAME=\$(cat /home/hostedcluster_name)

if [[ \$WORKER_IPS == *" "* ]]; then
  IFS=' ' read -ra parts <<< "\$WORKER_IPS"
  WORKER_IP0="\${parts[0]}"
  WORKER_IP1="\${parts[1]}"
  echo "address=/api.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP0" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP0" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP1" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP1" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
else
  WORKER_IP=\$WORKER_IPS
  if [[ "\$WORKER_IP" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$ ]]; then
    echo "It is an IPv4 address: \$WORKER_IP"
    echo "address=/api.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
    echo "address=/api-int.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
    echo "address=/.apps.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  elif [[ "\$WORKER_IP" =~ ^[0-9a-fA-F:]+\$ ]]; then
    echo "It is an IPv6 address: \$WORKER_IP"
    echo "address=/api.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
    echo "address=/api-int.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/\$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
    echo "address=/.apps.\$HOSTEDCLUSTER_NAME.\$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  else
    echo "Neither IPv4 nor IPv6, exiting with status code 1"
    exit 1
  fi
fi

systemctl restart NetworkManager.service
virsh net-dumpxml ostestbm > /tmp/ostestbm.xml
sed -i 's/<dns>/<dns>\n    <forwarder domain='"'"\$BASEDOMAIN"'"' addr='"'"'127.0.0.1'"'"'\/>/' /tmp/ostestbm.xml
virsh net-define /tmp/ostestbm.xml
virsh net-destroy ostestbm;virsh net-start ostestbm
systemctl restart libvirtd.service
set -x
EOF