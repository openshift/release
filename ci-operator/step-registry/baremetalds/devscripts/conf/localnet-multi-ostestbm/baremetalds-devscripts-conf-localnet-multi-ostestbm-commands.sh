#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf localnet-multi ostestbm ************"

if [[ "${ATTACH_DEFAULT_NETWORK:-}" != "localnet-multi" ]]; then
  echo "ATTACH_DEFAULT_NETWORK is not localnet-multi; skipping ostestbm configuration"
  exit 0
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME=$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-20)

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IP_STACK:-v4}" "${CLUSTER_NAME}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail
set -x

IP_STACK="${1}"
HOSTEDCLUSTER_NAME="${2}"
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
INGRESS_VIP="192.168.111.4"
DHCP_RANGE_START="192.168.111.100"
DHCP_RANGE_END="192.168.111.240"

echo "Configuring ostestbm for localnet-multi: DHCP pool ${DHCP_RANGE_START}-${DHCP_RANGE_END}, DNS for ${HOSTEDCLUSTER_NAME}.${BASEDOMAIN}"

DNSMASQ_CONF="/etc/NetworkManager/dnsmasq.d/openshift-ostest.conf"
touch "${DNSMASQ_CONF}"
if [[ "${IP_STACK}" == "v4v6" || "${IP_STACK}" == "v6v4" ]]; then
  echo "address=/.apps.${HOSTEDCLUSTER_NAME}.${BASEDOMAIN}/fd2e:6f44:5dd8:c956::1e" >> "${DNSMASQ_CONF}"
fi
if [[ "${IP_STACK}" == "v4" || "${IP_STACK}" == "v4v6" || "${IP_STACK}" == "v6v4" ]]; then
  echo "address=/api.${HOSTEDCLUSTER_NAME}.${BASEDOMAIN}/${INGRESS_VIP}" >> "${DNSMASQ_CONF}"
  echo "address=/api-int.${HOSTEDCLUSTER_NAME}.${BASEDOMAIN}/${INGRESS_VIP}" >> "${DNSMASQ_CONF}"
  echo "address=/.apps.${HOSTEDCLUSTER_NAME}.${BASEDOMAIN}/${INGRESS_VIP}" >> "${DNSMASQ_CONF}"
fi
nmcli general reload dns-full

virsh net-dumpxml ostestbm > /tmp/ostestbm.xml

if ! grep -qE 'forward.*mode=.nat.' /tmp/ostestbm.xml; then
  echo "ERROR: ostestbm is not in NAT forward mode; worker masquerading may fail" >&2
  exit 1
fi
echo "Verified ostestbm forward mode=nat"

# Replace any existing DHCP range with the widened pool (avoids node .20-.25, VIPs .4/.5, MetalLB .30-.50).
if grep -q '<range ' /tmp/ostestbm.xml; then
  sed -i -E "s|<range start='[^']*' end='[^']*'/>|<range start='${DHCP_RANGE_START}' end='${DHCP_RANGE_END}'/>|g" /tmp/ostestbm.xml
else
  sed -i "s|</dhcp>|  <range start='${DHCP_RANGE_START}' end='${DHCP_RANGE_END}'/>\n    </dhcp>|" /tmp/ostestbm.xml
fi

if ! grep -q "forwarder domain='${BASEDOMAIN}'" /tmp/ostestbm.xml; then
  sed -i "s|<dns>|<dns>\n    <forwarder domain='${BASEDOMAIN}' addr='127.0.0.1'/>|" /tmp/ostestbm.xml
fi

virsh net-define /tmp/ostestbm.xml
virsh net-destroy ostestbm || true
virsh net-start ostestbm
systemctl restart libvirtd.service

echo "ostestbm DHCP range ${DHCP_RANGE_START}-${DHCP_RANGE_END} and DNS forwarder for ${BASEDOMAIN} configured"
EOF
