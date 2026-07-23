#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
set -x

install_jq() {
  local jq_version
  jq_version=$(curl -s https://api.github.com/repos/jqlang/jq/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
  curl -sSfL "https://github.com/jqlang/jq/releases/download/${jq_version}/jq-linux-amd64" -o /tmp/jq
  chmod u+x /tmp/jq
  export PATH=${PATH}:/tmp
}

deploy_catalog() {
  echo "====> Using catalog image $CATALOG_IMAGE"
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_NAME
  namespace: openshift-marketplace
spec:
  displayName: NetObservMain
  image: $CATALOG_IMAGE
  sourceType: grpc
EOF
}

create_ns() {
  cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: openshift-netobserv-operator
EOF
}

create_og() {
  cat <<EOF | oc apply -f -
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  upgradeStrategy: Default
EOF
}

subscribe(){
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: ${CHANNEL}
  name: netobserv-operator
  source: ${CATALOG_NAME}
  sourceNamespace: openshift-marketplace 
EOF
}

patch_csv_images(){
  CSV=$(oc get csv -n openshift-netobserv-operator | grep -iE "net.*observ" | awk '{print $1}')

  if [[ $PATCH_EBPFAGENT_IMAGE ]]; then
    OVERRIDE_VAR="RELATED_IMAGE_EBPF_AGENT"
    echo "====> Patching eBPF image"
    ENV_INDEX=$(oc get csv/$CSV -n openshift-netobserv-operator -o json | jq --arg override_var "$OVERRIDE_VAR" '.spec.install.spec.deployments[0].spec.template.spec.containers[0].env | map(.name) | index($override_var)')
    oc patch csv/$CSV -n openshift-netobserv-operator --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/${ENV_INDEX}/value\", \"value\": \"$PATCH_EBPFAGENT_IMAGE\"}]"
  fi 

  if [[ $PATCH_FLOWLOGS_IMAGE ]]; then
    echo "====> Patching FLP image"
    OVERRIDE_VAR="RELATED_IMAGE_FLOWLOGS_PIPELINE"
    ENV_INDEX=$(oc get csv/$CSV -n openshift-netobserv-operator -o json | jq --arg override_var "$OVERRIDE_VAR" '.spec.install.spec.deployments[0].spec.template.spec.containers[0].env | map(.name) | index($override_var)')
    oc patch csv/$CSV -n openshift-netobserv-operator --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/${ENV_INDEX}/value\", \"value\": \"$PATCH_FLOWLOGS_IMAGE\"}]"
  fi

  if [[ $PATCH_CONSOLE_PLUGIN_IMAGE ]]; then
    if [[ $OCP_VERSION -ge "416" && $OCP_VERSION -le "421" ]]; then
      OVERRIDE_VAR="RELATED_IMAGE_WEB_CONSOLE_PF5"
    elif [[ $OCP_VERSION -le "415" ]]; then
      OVERRIDE_VAR="RELATED_IMAGE_WEB_CONSOLE_PF4"
    else
      OVERRIDE_VAR="RELATED_IMAGE_WEB_CONSOLE"
    fi
    echo $OVERRIDE_VAR

    ENV_INDEX=$(oc get csv/$CSV -n openshift-netobserv-operator -o json | jq --arg override_var "$OVERRIDE_VAR" '.spec.install.spec.deployments[0].spec.template.spec.containers[0].env | map(.name) | index($override_var)')
    oc patch csv/$CSV -n openshift-netobserv-operator --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/${ENV_INDEX}/value\", \"value\": \"$PATCH_CONSOLE_PLUGIN_IMAGE\"}]"
  fi

  if [[ $PATCH_OPERATOR_IMAGE ]]; then
      PATCH="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"$PATCH_OPERATOR_IMAGE\"}]"
      oc patch csv/$CSV -n openshift-netobserv-operator --type='json' -p="$PATCH"
  fi
}

if [[ "$CATALOG_SOURCE" == "source" ]]; then
    echo "====> Using upstream catalog bundle with tag: vmain"
    CATALOG_IMAGE="quay.io/netobserv/network-observability-operator-catalog:v0.0.0-sha-main"
    CATALOG_NAME="netobserv-main"
    CHANNEL="latest" # for upstream catalog source "latest" is the channel name.
    deploy_catalog
fi

NAMESPACE=netobserv
oc new-project ${NAMESPACE} || true

sleep 30
oc wait --timeout=180s --for=condition=ready pod -l olm.catalogSource=$CATALOG_NAME -n openshift-marketplace

jq --version || install_jq 
create_ns
create_og
subscribe

sleep 60
oc wait --timeout=180s --for=condition=ready pod -l app=netobserv-operator -n openshift-netobserv-operator

while :; do
    oc get crd/flowcollectors.flows.netobserv.io && break
    sleep 1
done

patch_csv_images
timeout=0
rc=1
while [ $timeout -lt 180 ]; do
    oc get pods -n openshift-netobserv-operator -l app=netobserv-operator | (! grep -vE "NAME|Running") && rc=0 && break
    sleep 30
    timeout=$((timeout+30))
done
exit $rc
