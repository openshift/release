#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

POOL_RANGE="192.168.111.30-192.168.111.50"

# Pin L2 announcements to the baremetal network interface only.
# Without this, extra network interfaces (e.g. from nmstate) can cause
# MetalLB speakers to announce VIPs on the wrong interface, making
# LoadBalancer IPs unreachable from the infra cluster.
# In OVN environments the baremetal network (192.168.111.0/24) lives on
# br-ex (OVS external bridge). With OpenShiftSDN the raw NIC keeps the
# IP directly. Detect the network type and choose accordingly.
NETWORK_TYPE=$(oc get network.config cluster -o jsonpath='{.status.networkType}')
if [[ "${NETWORK_TYPE}" == "OVNKubernetes" ]]; then
  METALLB_IFACE="br-ex"
else
  METALLB_IFACE="enp2s0"
fi
echo "Detected network type ${NETWORK_TYPE}, using interface ${METALLB_IFACE} for L2 advertisements"

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - ${POOL_RANGE}
EOF

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
   - metallb
  interfaces:
   - ${METALLB_IFACE}
EOF
