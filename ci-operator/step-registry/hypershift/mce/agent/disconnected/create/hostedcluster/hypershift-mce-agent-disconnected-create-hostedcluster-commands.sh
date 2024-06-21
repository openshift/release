#!/bin/bash

set -ex

echo "************ MCE agent disconnected create HostedCluster command ************"

source "${SHARED_DIR}/packet-conf.sh"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeo pipefail

if [ -f /root/config ] ; then
  source /root/config
fi

export DISCONNECTED="${DISCONNECTED:-}"
export IP_STACK="${IP_STACK:-}"

arch=\$(arch)
if [ "\$arch" == "x86_64" ]; then
  downURL=\$(oc get ConsoleCLIDownload hcp-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/hcp.tar.gz \${downURL}
  cd /tmp && tar -xvf /tmp/hcp.tar.gz
  chmod +x /tmp/hcp
  cd -
fi

if [ ! -f /tmp/yq-v4 ]; then
  curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_\$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
fi
oc get imagecontentsourcepolicy -oyaml | /tmp/yq-v4 '.items[] | .spec.repositoryDigestMirrors' > /home/mgmt_icsp.yaml

CLUSTER_NAME=\$(cat /home/hostedcluster_name)
CLUSTER_NAMESPACE=local-cluster-\${CLUSTER_NAME}
echo "\$(date) Creating HyperShift cluster \${CLUSTER_NAME}"
oc create ns "\${CLUSTER_NAMESPACE}"
BASEDOMAIN=\$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
PLAYLOADIMAGE=\$(oc get clusterversion version -ojsonpath='{.status.desired.image}')

EXTRA_ARGS=""
if [[ "\$DISCONNECTED" == "true" ]]; then
  EXTRA_ARGS+=\$(echo "--additional-trust-bundle /etc/pki/ca-trust/source/anchors/registry.2.crt ")
  EXTRA_ARGS+="--olm-disable-default-sources "
fi

if [[ "\${IP_STACK}" == "v6" ]]; then
  EXTRA_ARGS+="--cluster-cidr fd03::/48 --service-cidr fd04::/112 "
fi

if [[ "\${IP_STACK}" == "v4v6" ]]; then
  EXTRA_ARGS+="--cluster-cidr 10.132.0.0/14 --cluster-cidr fd03::/48 --service-cidr 172.31.0.0/16 --service-cidr fd04::/112 "
fi

/tmp/hcp create cluster agent \${EXTRA_ARGS} \
  --name=\${CLUSTER_NAME} \
  --pull-secret=/tmp/.dockerconfigjson \
  --agent-namespace="\${CLUSTER_NAMESPACE}" \
  --namespace local-cluster \
  --base-domain=\${BASEDOMAIN} \
  --api-server-address=api.\${CLUSTER_NAME}.\${BASEDOMAIN} \
  --image-content-sources "/home/mgmt_icsp.yaml" \
  --release-image \${PLAYLOADIMAGE}

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=local-cluster hostedcluster/\${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
/tmp/hcp create kubeconfig --namespace=local-cluster --name=\${CLUSTER_NAME} > /home/nested_kubeconfig
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/home/nested_kubeconfig" "${SHARED_DIR}/nested_kubeconfig"