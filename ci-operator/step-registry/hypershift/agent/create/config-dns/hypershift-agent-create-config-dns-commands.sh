#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ config-dns command ************"

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$CLUSTER_NAME" > /tmp/hostedcluster_name
scp "${SSHOPTS[@]}" "/tmp/hostedcluster_name" "root@${IP}:/home/hostedcluster_name"

# 192.168.111.30 points to the MetalLB ingress IPs configured in
# the hypershift-agent-create-metallb step on dev-scripts default
# external network (192.168.111.0/24). Fallback to the default if the
INGRESS_VIP=192.168.111.30
if [[ -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
  INGRESS_VIP=$(source "${SHARED_DIR}/nutanix_context.sh" && printf '%s' "${INGRESS_VIP:?}")
fi

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IP_STACK}" "${CLUSTER_NAME}" "${INGRESS_VIP}" << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -o nounset
set -o errexit
set -o pipefail
set -x

IP_STACK="${1}"
HOSTEDCLUSTER_NAME="${2}"
INGRESS_VIP="${3}"

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
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$INGRESS_VIP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
elif [[ $IP_STACK == "v6" ]]; then
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  # The fd2e:6f44:5dd8:c956::1e address is the IPv6 variant of MetalLB ingress IPs
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
elif [[ $IP_STACK == "v4" ]]; then
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$INGRESS_VIP" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
else
  echo "$IP_STACK don't support"
  exit 1
fi

nmcli general reload dns-full
virsh net-dumpxml ostestbm > /tmp/ostestbm.xml
sed -i 's/<dns>/<dns>\n    <forwarder domain='"'"$BASEDOMAIN"'"' addr='"'"'127.0.0.1'"'"'\/>/' /tmp/ostestbm.xml
virsh net-define /tmp/ostestbm.xml
virsh net-destroy ostestbm;virsh net-start ostestbm
systemctl restart libvirtd.service
EOF
