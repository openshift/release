#!/bin/bash

set -e

function exit_with_failure() {
  oc get pod -n openshift-marketplace > "$ARTIFACT_DIR/openshift-marketplace-pod"
  oc get pod -n openshift-marketplace -o yaml > "$ARTIFACT_DIR/openshift-marketplace-pod-yaml"
  oc get pod -n multicluster-engine > "$ARTIFACT_DIR/multicluster-engine-pod"
  oc get pod -n multicluster-engine -o yaml > "$ARTIFACT_DIR/multicluster-engine-pod-yaml"
  exit 1
}

trap 'exit_with_failure' ERR

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION:-}" ]]; then
  MCE_VERSION="$MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION"
fi

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OVERRIDE_HO_IMAGE:-}" ]]; then
  OVERRIDE_HO_IMAGE="$MULTISTAGE_PARAM_OVERRIDE_OVERRIDE_HO_IMAGE"
fi

echo "$MCE_VERSION"

# Enable Hypershift Preview
oc apply -f - <<EOF
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine-sample
spec: {}
EOF
sleep 5

oc patch mce multiclusterengine-sample --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift-preview","enabled": true}]}}}'
echo "wait for mce to Available"
oc wait --timeout=20m --for=condition=Available MultiClusterEngine/multiclusterengine-sample

oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  labels:
    local-cluster: "true"
  name: local-cluster
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF
oc wait --timeout=5m --for=condition=HubAcceptedManagedCluster -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterImportSucceeded -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterConditionAvailable -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterJoined -n local-cluster ManagedCluster/local-cluster
echo "MCE local-cluster is ready!"

oc apply -f - <<EOF
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: hypershift-addon
  namespace: local-cluster
spec:
  installNamespace: open-cluster-management-agent-addon
EOF

# wait for hypershift operator to come online
_hypershiftReady=0
set +e
for ((i=1; i<=30; i++)); do
  if oc get pods -n hypershift | grep -q "operator.*Running"; then
    _hypershiftReady=1
    break
  fi
  echo "Waiting on hypershift operator ($i/20)"
  sleep 10
done
set -e

if [ $_hypershiftReady -eq 0 ]; then
  echo "hypershift operator did not come online in expected time"
  exit 1
fi
echo "hypershift is running! Waiting for the pods to become ready"

oc wait deployment operator -n hypershift --for condition=Available=True --timeout=5m

HUB_CLUSTER_ARCH=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
if [ "$HUB_CLUSTER_ARCH" != "s390x" ]; then
  echo "Cluster architecture is $HUB_CLUSTER_ARCH. Proceeding..."
  echo "Configuring the hosting service cluster"
  oc create secret generic hypershift-operator-oidc-provider-s3-credentials --from-file=credentials=/etc/hypershift-pool-aws-credentials/credentials --from-literal=bucket=hypershift-ci-oidc --from-literal=region=us-east-1 -n local-cluster
  oc label secret hypershift-operator-oidc-provider-s3-credentials -n local-cluster cluster.open-cluster-management.io/backup=true

  # wait for Configuring the hosting service cluster
  _configReady=0
  trap - ERR
  set +e
  for ((i=1; i<=30; i++)); do
  oc get configmap -n kube-public oidc-storage-provider-s3-config
    if [ $? -eq 0 ]; then
      _configReady=1
      break
    fi
    echo "Waiting on Configuring the hosting service cluster"
    sleep 30
  done
  set -e
  trap 'exit_with_failure' ERR
  if [ $_configReady -eq 0 ]; then
    echo "Configuring error"
    exit 1
  fi
  echo "Configuring the hosting service cluster Succeeded!"
else
  echo "Cluster architecture is s390x. Skipping this section."
fi

# export icsp for hypershift hostedcluster if needed
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_icsp.yaml

echo "wait for addon to Available"
oc wait --timeout=5m --for=condition=Available -n local-cluster ManagedClusterAddOn/hypershift-addon
oc wait --timeout=5m --for=condition=Degraded=False -n local-cluster ManagedClusterAddOn/hypershift-addon

if [[ "$USE_KONFLUX_CATALOG" == "true" ]]; then
  declare -A konflux_mce_image_list=(
    [2.6]="quay.io/redhat-user-workloads/crt-redhat-acm-tenant/release-mce-26/hypershift-release-mce-26:latest"
    [2.7]="quay.io/redhat-user-workloads/crt-redhat-acm-tenant/release-mce-27/hypershift-release-mce-27:latest"
    [2.8]="quay.io/redhat-user-workloads/crt-redhat-acm-tenant/hypershift-release-mce-28:latest"
    [2.9]="quay.io/redhat-user-workloads/crt-redhat-acm-tenant/hypershift-release-mce-29:latest"
    [2.10]="quay.io/redhat-user-workloads/crt-redhat-acm-tenant/hypershift-release-mce-210:latest"
  )
  OVERRIDE_HO_IMAGE="${konflux_mce_image_list[$MCE_VERSION]}"
fi
if [[ ${OVERRIDE_HO_IMAGE} ]] ; then
  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: hypershift-override-images
  namespace: local-cluster
data:
  hypershift-operator: ${OVERRIDE_HO_IMAGE}
EOF
  while ! [[ "$(oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[*].image}')" == "$OVERRIDE_HO_IMAGE" ]]; do
      echo "wait override hypershift operator IMAGE..."
      sleep 10
  done
  oc wait deployment -n hypershift operator --for=condition=Available --timeout=5m
fi

# display HyperShift cli version
HYPERSHIFT_NAME=hcp
arch=$(arch)
if [ "$arch" == "x86_64" ]; then
  # The HCP CLI download route may not be ready immediately after the operator becomes available.
  # Retry with backoff to avoid failing on a transient HTML error page instead of the binary.
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
  _hcp_downloaded=false
  for i in $(seq 1 10); do
    if curl -k --output /tmp/${HYPERSHIFT_NAME}.tar.gz "${downURL}" && tar -tzf /tmp/${HYPERSHIFT_NAME}.tar.gz &>/dev/null; then
      _hcp_downloaded=true
      break
    fi
    echo "HCP CLI download failed or archive is invalid, retrying in 30s... ($i/10)"
    sleep 30
  done
  if [ "$_hcp_downloaded" = false ]; then
    echo "ERROR: Failed to download valid HCP CLI after 5 minutes."
    exit 1
  fi
  cd /tmp && tar -xvf /tmp/${HYPERSHIFT_NAME}.tar.gz
  chmod +x /tmp/${HYPERSHIFT_NAME}
  cd -
fi
/tmp/${HYPERSHIFT_NAME} version

# display HyperShift Operator Version and MCE version
oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" > "$ARTIFACT_DIR/mce-version"
oc get deployment -n hypershift operator -ojsonpath='{.spec.template.spec.containers[*].image}' > "$ARTIFACT_DIR/hypershiftoperator-image"
oc logs -n hypershift -lapp=operator --tail=-1 -c operator | head -1 | jq > "$ARTIFACT_DIR/hypershift-version"
