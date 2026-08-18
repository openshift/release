#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Source ds-vars.conf if available to get IP_STACK from management cluster
IP_STACK=${IP_STACK:-v4}
if [ -f "${SHARED_DIR}/ds-vars.conf" ]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/ds-vars.conf"
  IP_STACK=${DS_IP_STACK:-v4}
fi

echo "Waiting for MetalLB webhook to be ready..."
oc wait deployment metallb-operator-controller-manager \
  -n metallb-system --for=condition=Available --timeout=300s

for attempt in $(seq 1 5); do
  if oc create -f - <<'METALLB_EOF'
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
METALLB_EOF
  then
    break
  fi
  if [[ ${attempt} -eq 5 ]]; then
    echo "MetalLB CR creation failed after ${attempt} attempts"
    exit 1
  fi
  echo "MetalLB CR creation attempt ${attempt} failed, retrying in 10s..."
  sleep 10
done

echo "Configure IPAddressPool for IP_STACK=${IP_STACK}"
if [[ $IP_STACK == "v4" ]]; then
  oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - 192.168.111.30-192.168.111.50
EOF
elif [[ $IP_STACK == "v4v6" ]] || [[ $IP_STACK == "v6v4" ]]; then
  # For dual-stack, provide both IPv4 and IPv6 address pools
  # The order doesn't matter for MetalLB - it just makes both ranges available
  # The fd2e:6f44:5dd8:c956:: prefix is standard for baremetalds environments
  oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - 192.168.111.30-192.168.111.50
  - fd2e:6f44:5dd8:c956::100-fd2e:6f44:5dd8:c956::110
EOF
elif [[ $IP_STACK == "v6" ]]; then
  oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - fd2e:6f44:5dd8:c956::100-fd2e:6f44:5dd8:c956::110
EOF
else
  echo "Unsupported IP_STACK: $IP_STACK"
  exit 1
fi

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
   - metallb
EOF
