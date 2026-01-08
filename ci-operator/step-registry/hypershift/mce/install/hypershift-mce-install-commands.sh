#!/bin/bash

set -ex

function exit_with_failure() {
  oc get pod -n openshift-marketplace > "$ARTIFACT_DIR/openshift-marketplace-pod"
  oc get pod -n openshift-marketplace -o yaml > "$ARTIFACT_DIR/openshift-marketplace-pod-yaml"
  oc get pod -n multicluster-engine > "$ARTIFACT_DIR/multicluster-engine-pod"
  oc get pod -n multicluster-engine -o yaml > "$ARTIFACT_DIR/multicluster-engine-pod-yaml"
  exit 1
}

trap 'exit_with_failure' ERR

env

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -n "$MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION" ]]; then
    MCE_VERSION="$MULTISTAGE_PARAM_OVERRIDE_MCE_VERSION"
fi

echo "$MCE_VERSION"

MCE_CATALOG_PATH="acm-d/mce-custom-registry"
_REPO="quay.io/$MCE_CATALOG_PATH"
if [[ "$(printf '%s\n' "2.6" "$MCE_VERSION" | sort -V | head -n1)" == "2.6" ]]; then
  MCE_CATALOG_PATH="acm-d/mce-dev-catalog"
  _REPO="quay.io:443/$MCE_CATALOG_PATH"
fi
if [[ "$DISCONNECTED" == "true" ]]; then
  _REPO=$(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6001/g')/$MCE_CATALOG_PATH
  # Setup disconnected quay mirror container repo
  oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - $(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6001/g')/acm-d
    source: quay.io/acm-d
  - mirrors:
    - $(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6001/g')/acm-d
    source: registry.redhat.io/rhacm2
  - mirrors:
    - $(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6001/g')/acm-d
    source: registry.redhat.io/multicluster-engine
  - mirrors:
    - $(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6001/g')/acm-d
    source: registry.stage.redhat.io/multicluster-engine
  - mirrors:
    - $(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6002/g')/openshift4/ose-oauth-proxy
    source: registry.access.redhat.com/openshift4/ose-oauth-proxy
EOF
  oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: rhacm-repo
spec:
  imageTagMirrors:
  - mirrors:
    - $(head -n 1 "${SHARED_DIR}/mirror_registry_url" | sed 's/5000/6001/g')/acm-d
    source: quay.io/acm-d
EOF
else
  # Setup quay mirror container repo
  cat << EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/rhacm2
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/multicluster-engine
  - mirrors:
    - registry.redhat.io/openshift4/ose-oauth-proxy
    source: registry.access.redhat.com/openshift4/ose-oauth-proxy
EOF

  QUAY_USERNAME=$(cat /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username)
  QUAY_PASSWORD=$(cat /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_pullsecret)
  oc get secret pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/global-pull-secret.json
  QUAY_AUTH=$(echo -n "${QUAY_USERNAME}:${QUAY_PASSWORD}" | base64 -w 0)
  jq --arg QUAY_AUTH "$QUAY_AUTH" '.auths += {"quay.io:443": {"auth":$QUAY_AUTH,"email":""}}' /tmp/global-pull-secret.json > /tmp/global-pull-secret.json.tmp
  mv /tmp/global-pull-secret.json.tmp /tmp/global-pull-secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/global-pull-secret.json
  rm /tmp/global-pull-secret.json
fi

sleep 60
oc wait mcp master worker --for condition=updated --timeout=30m

echo "Install MCE custom catalog source"
IMG="${_REPO}:${MCE_VERSION}-latest"
if [[ "$(printf '%s\n' "2.6" "$MCE_VERSION" | sort -V | head -n1)" == "2.6" ]]; then
  IMG="${_REPO}:latest-${MCE_VERSION}"
fi
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: multiclusterengine-catalog
  namespace: openshift-marketplace
spec:
  displayName: MultiCluster Engine
  publisher: Red Hat
  sourceType: grpc
  image: ${IMG}
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
oc wait CatalogSource --timeout=20m --for=jsonpath='{.status.connectionState.lastObservedState}'=READY -n openshift-marketplace multiclusterengine-catalog

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: multicluster-engine
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: multicluster-engine-group
  namespace: multicluster-engine
spec:
  targetNamespaces:
    - "multicluster-engine"
EOF

echo "* Applying SUBSCRIPTION_CHANNEL $MCE_VERSION, SUBSCRIPTION_SOURCE multiclusterengine-catalog to multiclusterengine-operator subscription"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-${MCE_VERSION}
  installPlanApproval: Automatic
  name: multicluster-engine
  source: multiclusterengine-catalog
  sourceNamespace: openshift-marketplace
EOF

CSVName=""
for ((i=1; i<=60; i++)); do
  output=$(oc get sub multicluster-engine -n multicluster-engine -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=$(oc get sub -n multicluster-engine multicluster-engine -o jsonpath='{.status.currentCSV}')
  if [ "$CSVName" != "" ]; then
    break
  fi
  sleep 20
done

_apiReady=0
echo "* Using CSV: ${CSVName}"
for ((i=1; i<=40; i++)); do
  sleep 30
  output=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    continue
  fi
  phase=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}')
  if [ "$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ $_apiReady -eq 0 ]; then
  echo "multiclusterengine subscription could not install in the allotted time."
  exit 1
fi
echo "multiclusterengine installed successfully"

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

echo "Configuring the hosting service cluster"
oc create secret generic hypershift-operator-oidc-provider-s3-credentials --from-file=credentials=/etc/hypershift-pool-aws-credentials/credentials --from-literal=bucket=hypershift-ci-oidc --from-literal=region=us-east-1 -n local-cluster
oc label secret hypershift-operator-oidc-provider-s3-credentials -n local-cluster cluster.open-cluster-management.io/backup=true
# wait for Configuring the hosting service cluster
_configReady=0
trap - ERR
set +e
for ((i=1; i<=10; i++)); do
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
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/${HYPERSHIFT_NAME}.tar.gz ${downURL}
  cd /tmp && tar -xvf /tmp/${HYPERSHIFT_NAME}.tar.gz
  chmod +x /tmp/${HYPERSHIFT_NAME}
  cd -
fi
/tmp/${HYPERSHIFT_NAME} version

# display HyperShift Operator Version and MCE version
oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" > "$ARTIFACT_DIR/mce-version"
oc get deployment -n hypershift operator -ojsonpath='{.spec.template.spec.containers[*].image}' > "$ARTIFACT_DIR/hypershiftoperator-image"
oc logs -n hypershift -lapp=operator --tail=-1 -c operator | head -1 | jq > "$ARTIFACT_DIR/hypershift-version"