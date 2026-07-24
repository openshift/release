#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

CILIUM_VERSION="${CILIUM_VERSION:-1.19.4}"
CILIUM_REPOSITORY="${CILIUM_REPOSITORY:-oci://quay.io/cilium/charts/cilium}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-0.19.2}"
ENDPOINT_ROUTES="${ENDPOINT_ROUTES:-true}"
HUBBLE="${HUBBLE:-true}"
TUNNEL_PORT="${TUNNEL_PORT:-4790}"
SHARED_DIR="${SHARED_DIR:-/tmp/shared_dir}"

if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
  sed -i "s/networkType: .*/networkType: Cilium/" "${SHARED_DIR}/install-config.yaml"
fi

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: Cilium
  serviceNetwork:
  - 172.30.0.0/16
EOF

mkdir -p /tmp/bin
curl --fail --retry 3 -sS -L \
  "https://github.com/cilium/cilium-cli/releases/download/v${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
  | tar -xzC /tmp/bin/
chmod +x /tmp/bin/cilium
export PATH=/tmp/bin:$PATH

cat > "${SHARED_DIR}/manifest_cilium-00-namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cilium
EOF

# Workaround for OCPBUGS-85607: Apply Cilium NetworkPolicy to allow DNS pods to reach kube-apiserver
# This needs to be applied on the management cluster for Hypershift Cilium jobs
cat > "${SHARED_DIR}/manifest_cilium-00-network-policy-dns.yaml" <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-allow-kube-apiserver
  namespace: openshift-dns
spec:
  endpointSelector:
    matchLabels:
      dns.operator.openshift.io/daemonset-dns: default
  egress:
  - toEntities:
    - host
    - kube-apiserver
EOF

cat > "${SHARED_DIR}/manifest_cilium-00-scc-privileged.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cilium-scc-privileged
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
- kind: ServiceAccount
  name: cilium
  namespace: cilium
- kind: ServiceAccount
  name: cilium-operator
  namespace: cilium
- kind: ServiceAccount
  name: cilium-envoy
  namespace: cilium
EOF

WORKDIR=$(mktemp -d)

# Note: In order to test with a development version, use:
# --repository oci://quay.io/cilium-charts-dev/cilium --version <version>
# where <version> is a tag from https://quay.io/repository/cilium-charts-dev/cilium
cilium install \
    --dry-run \
    --namespace cilium \
    --repository "${CILIUM_REPOSITORY}" \
    --version "${CILIUM_VERSION}" \
    --set debug.enabled=true \
    --set k8s.requireIPv4PodCIDR=true \
    --set logSystemLoad=true \
    --set ipv6.enabled=false \
    --set identityChangeGracePeriod=0s \
    --set ipam.mode=cluster-pool \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={10.128.0.0/14}" \
    --set ipam.operator.clusterPoolIPv4MaskSize=23 \
    --set ipv4NativeRoutingCIDR=10.128.0.0/14 \
    --set cni.binPath=/var/lib/cni/bin \
    --set cni.confPath=/var/run/multus/cni/net.d \
    --set sessionAffinity=true \
    --set endpointRoutes.enabled="${ENDPOINT_ROUTES}" \
    --set hubble.enabled="${HUBBLE}" \
    --set tunnelPort="${TUNNEL_PORT}" \
    --set clusterHealthPort=9940 \
    --set socketLB.enabled=true \
    --set cni.readCniConf=/etc/cilium-cni/cilium-override.conf \
    --set extraVolumes[0].name=cni-override \
    --set extraVolumes[0].configMap.name=cilium-cni-override \
    --set extraVolumeMounts[0].name=cni-override \
    --set extraVolumeMounts[0].mountPath=/etc/cilium-cni \
    > "${WORKDIR}/cilium-install-all.yaml"

# Split the multi-document YAML into individual manifest files
csplit -z -f "${WORKDIR}/cilium-part-" -b '%02d.yaml' "${WORKDIR}/cilium-install-all.yaml" '/^---$/' '{*}'
INDEX=1
for f in "${WORKDIR}"/cilium-part-*.yaml; do
  sed -i '/^---$/d' "$f"
  [[ ! -s "$f" ]] && rm -f "$f" && continue
  PADDED=$(printf "%02d" "$INDEX")
  KIND=$(grep '^kind:' "$f" | head -1 | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
  NAME=$(grep '^  name:' "$f" | head -1 | awk '{print $2}' | tr -d '"')
  mv "$f" "${SHARED_DIR}/manifest_cilium-${PADDED}-${KIND}-${NAME}.yaml"
  INDEX=$((INDEX + 1))
done
