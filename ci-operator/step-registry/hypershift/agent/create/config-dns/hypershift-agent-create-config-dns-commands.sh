#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set +x

echo "************ config-dns command ************"

source "${SHARED_DIR}/packet-conf.sh"
# The sourced script may enable tracing again.
set +x

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$CLUSTER_NAME" > /tmp/hostedcluster_name
scp "${SSHOPTS[@]}" "/tmp/hostedcluster_name" "root@${IP}:/home/hostedcluster_name"

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IP_STACK}" "${CLUSTER_NAME}" << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -o nounset
set -o errexit
set -o pipefail
# DNS records and the forwarder contain internal hostnames.
set +x

IP_STACK="${1}"
HOSTEDCLUSTER_NAME="${2}"

WORKER_IPS=$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
WORKER_IPV4=""
WORKER_IPV6=""
for worker_ip in $WORKER_IPS; do
  if [[ "$worker_ip" == *:* ]]; then
    WORKER_IPV6="$worker_ip"
  else
    WORKER_IPV4="$worker_ip"
  fi
done
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")

# The .apps wildcard DNS entries point to the MetalLB ingress IPs configured in
# the hypershift-agent-create-metallb step: 192.168.111.30 (IPv4) and
# fd2e:6f44:5dd8:c956::1e (IPv6). These are from the dev-scripts default
# external network (192.168.111.0/24, fd2e:6f44:5dd8:c956::/120).
if [[ $IP_STACK == "v4v6" ]]; then
  : "${WORKER_IPV4:?No IPv4 worker address found}"
  : "${WORKER_IPV6:?No IPv6 worker address found}"
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV4" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV4" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV6" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV6" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
elif [[ $IP_STACK == "v6" ]]; then
  : "${WORKER_IPV6:?No IPv6 worker address found}"
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV6" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV6" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/fd2e:6f44:5dd8:c956::1e" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
elif [[ $IP_STACK == "v4" ]]; then
  : "${WORKER_IPV4:?No IPv4 worker address found}"
  echo "address=/api.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV4" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/api-int.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/$WORKER_IPV4" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
  echo "address=/.apps.$HOSTEDCLUSTER_NAME.$BASEDOMAIN/192.168.111.30" >> /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
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
