#!/bin/bash

set -exuo pipefail

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

echo "$CLUSTER_NAME" > /tmp/hostedcluster_name
scp "${SSHOPTS[@]}" "/tmp/hostedcluster_name" "root@${IP}:/home/hostedcluster_name"

echo "$HYPERSHIFT_NODE_COUNT" > /tmp/hypershift_node_count
scp "${SSHOPTS[@]}" "/tmp/hypershift_node_count" "root@${IP}:/home/hypershift_node_count"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeo pipefail

if [ -f /root/config ] ; then
source /root/config
fi

export DISCONNECTED="${DISCONNECTED:-}"
export IP_STACK="${IP_STACK:-}"

### workaround for https://issues.redhat.com/browse/OCPBUGS-29408
echo "workaround for https://issues.redhat.com/browse/OCPBUGS-29408"
# explicitly mirror the RHCOS image used by the selected release

mirror_registry=\$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
mirror_registry=\${mirror_registry%%/*}
if [[ \$mirror_registry == "" ]] ; then
  echo "Warning: Can not find the mirror registry, abort !!!"
  exit 1
fi
echo "mirror registry is \${mirror_registry}"

LOCALIMAGES=localimages

PAYLOADIMAGE=\$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
mkdir -p /home/release-manifests/
oc image extract \${PAYLOADIMAGE} --path /release-manifests/:/home/release-manifests/ --confirm
RHCOS_IMAGE=\$(cat /home/release-manifests/0000_50_installer_coreos-bootimages.yaml | yq -r .data.stream | jq -r '.architectures.x86_64.images.kubevirt."digest-ref"')
RHCOS_IMAGE_NO_DIGEST=\${RHCOS_IMAGE%@sha256*}
RHCOS_IMAGE_NAME=\${RHCOS_IMAGE_NO_DIGEST##*/}
RHCOS_IMAGE_REPO=\${RHCOS_IMAGE_NO_DIGEST%/*}

set +x
QUAY_USER=\$(cat "/home/registry_quay.json" | jq -r '.user')
QUAY_PASSWORD=\$(cat "/home/registry_quay.json" | jq -r '.password')
podman login quay.io -u "\${QUAY_USER}" -p "\${QUAY_PASSWORD}"
set -x
oc image mirror \${RHCOS_IMAGE} \${mirror_registry}/\${LOCALIMAGES}/\${RHCOS_IMAGE_NAME}

oc apply -f - <<EOF2
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: openshift-release-dev
spec:
  repositoryDigestMirrors:
    - mirrors:
        - \${mirror_registry}/\${LOCALIMAGES}
      source: \${RHCOS_IMAGE_REPO}
EOF2

###

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
oc get imagecontentsourcepolicy -oyaml | /tmp/yq-v4 '.items[] | .spec.repositoryDigestMirrors' > /home/mgmt_iscp.yaml
ICSP="--image-content-sources /home/mgmt_iscp.yaml "

HYPERSHIFT_NODE_COUNT=\$(cat /home/hypershift_node_count)

CLUSTER_NAME=\$(cat /home/hostedcluster_name)
CLUSTER_NAMESPACE=local-cluster-\${CLUSTER_NAME}
echo "\$(date) Creating HyperShift cluster \${CLUSTER_NAME}"
oc create ns "\${CLUSTER_NAMESPACE}"

echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
PULL_SECRET_PATH="/tmp/.dockerconfigjson"

### workaround for https://issues.redhat.com/browse/CNV-38194
echo "workaround for https://issues.redhat.com/browse/CNV-38194"
TRUST="--additional-trust-bundle /etc/pki/ca-trust/source/anchors/registry.2.crt "
###

### workaround for https://issues.redhat.com/browse/OCPBUGS-29466
echo "workaround for https://issues.redhat.com/browse/OCPBUGS-29466"
mkdir -p /home/idms
mkdir -p /home/icsp
for i in \$(oc get imageContentSourcePolicy -o name); do oc get \${i} -o yaml > /home/icsp/\$(basename \${i}).yaml ; done
for f in /home/icsp/*; do oc adm migrate icsp \${f} --dest-dir /home/idms ; done
oc apply -f /home/idms || true
###

### workaround for https://issues.redhat.com/browse/OCPBUGS-29110
echo "workaround for https://issues.redhat.com/browse/OCPBUGS-29110"
oc delete pods -n hypershift -l name=operator
sleep 180
###

### workaround for https://issues.redhat.com/browse/OCPBUGS-29494
echo "workaround for https://issues.redhat.com/browse/OCPBUGS-29494"
HO_OPERATOR_IMAGE="\${PAYLOADIMAGE//@sha256:[^ ]*/@\$(oc adm release info -a /tmp/.dockerconfigjson "\$PAYLOADIMAGE" | grep hypershift | awk '{print \$2}')}"
###

ETCD_STORAGE_CLASS=""
if [ "\$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "AWS" ]; then
  echo "AWS infra detected. Setting --etcd-storage-class"
  ETCD_STORAGE_CLASS="--etcd-storage-class gp3-csi"
fi

mirrored_index=\${mirror_registry}/olm-index/redhat-operator-index
OLM_CATALOGS_R_OVERRIDES=registry.redhat.io/redhat/certified-operator-index=\${mirrored_index},registry.redhat.io/redhat/community-operator-index=\${mirrored_index},registry.redhat.io/redhat/redhat-marketplace-index=\${mirrored_index},registry.redhat.io/redhat/redhat-operator-index=\${mirrored_index}

echo "\$(date) Creating HyperShift cluster \${CLUSTER_NAME}"
/tmp/hcp create cluster kubevirt \${ETCD_STORAGE_CLASS} \${ICSP} \${TRUST} \
  --annotations=hypershift.openshift.io/control-plane-operator-image=\${HO_OPERATOR_IMAGE} \
  --annotations=hypershift.openshift.io/olm-catalogs-is-registry-overrides=\${OLM_CATALOGS_R_OVERRIDES} \
  --name \${CLUSTER_NAME} \
  --node-pool-replicas \${HYPERSHIFT_NODE_COUNT} \
  --memory 16Gi \
  --cores 4 \
  --root-volume-size 64 \
  --namespace local-cluster \
  --release-image \${PAYLOADIMAGE} \
  --pull-secret \${PULL_SECRET_PATH} \
  --generate-ssh

oc annotate hostedclusters -n local-cluster \${CLUSTER_NAME} "cluster.open-cluster-management.io/managedcluster-name=\${CLUSTER_NAME}" --overwrite
oc apply -f - <<EOF2
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  annotations:
    import.open-cluster-management.io/hosting-cluster-name: local-cluster
    import.open-cluster-management.io/klusterlet-deploy-mode: Hosted
    open-cluster-management/created-via: other
  labels:
    cloud: auto-detect
    cluster.open-cluster-management.io/clusterset: default
    name: \${CLUSTER_NAME}
    vendor: OpenShift
  name: \${CLUSTER_NAME}
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF2

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=local-cluster hostedcluster/\${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
/tmp/hcp create kubeconfig --namespace=local-cluster --name=\${CLUSTER_NAME} > /home/nested_kubeconfig

EOF

scp "${SSHOPTS[@]}" "root@${IP}:/home/nested_kubeconfig" "${SHARED_DIR}/nested_kubeconfig"
