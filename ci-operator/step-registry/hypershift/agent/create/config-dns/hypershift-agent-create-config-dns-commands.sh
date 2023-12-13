#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ config-dns command ************"

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$CLUSTER_NAME" > /tmp/hostedcluster_name
scp "${SSHOPTS[@]}" "/tmp/hostedcluster_name" "root@${IP}:/home/hostedcluster_name"

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IP_STACK}" "${CLUSTER_NAME}" << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -o nounset
set -o errexit
set -o pipefail
set -x

IP_STACK="${1}"
HOSTEDCLUSTER_NAME="${2}"

WORKER_IP=$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")

if [[ $IP_STACK == "v4v6" ]]; then
  IFS=' ' read -ra parts <<< "$WORKER_IP"
  WORKER_IP0="${parts[0]}"
  WORKER_IP1="${parts[1]}"
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP0" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP0" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP1" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP1" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
elif [[ $IP_STACK == "v6" ]]; then
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
elif [[ $IP_STACK == "v4" ]]; then
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
else
  echo "$IP_STACK don't support"
  exit 1
fi

systemctl restart NetworkManager.service
virsh net-dumpxml ostestbm > /tmp/ostestbm.xml
sed -i 's/<dns>/<dns>\n    <forwarder domain='"'"$BASEDOMAIN"'"' addr='"'"'127.0.0.1'"'"'\/>/' /tmp/ostestbm.xml
virsh net-define /tmp/ostestbm.xml
virsh net-destroy ostestbm;virsh net-start ostestbm
systemctl restart libvirtd.service
EOF
