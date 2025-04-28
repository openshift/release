#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

update_flowcollector() {
  FLOWCOLLECTOR=/tmp/flowcollector.yaml
  cat <<EOF >$FLOWCOLLECTOR
kind: FlowCollector
apiVersion: flows.netobserv.io/v1beta2
metadata:
  name: cluster
spec:
  agent:
    ebpf:
      cacheActiveTimeout: 5s
      cacheMaxFlows: 100000
      features: []
      sampling: 1
    type: eBPF
  consolePlugin:
    logLevel: info
    portNaming:
      enable: true
      portNames:
        '3100': loki
  deploymentModel: Direct
  exporters: []
  kafka:
    address: kafka-cluster-kafka-bootstrap.netobserv
    tls:
      caCert:
        certFile: ca.crt
        name: kafka-cluster-cluster-ca-cert
        type: secret
      enable: false
      userCert:
        certFile: user.crt
        certKey: user.key
        name: flp-kafka
        type: secret
    topic: network-flows
  loki:
    enable: true
    lokiStack:
      name: loki
    mode: Monolithic
  namespace: netobserv
  processor:
    kafkaConsumerReplicas: 3
    logLevel: info
    logTypes: Flows
    profilePort: 6060
    resources:
      limits:
        memory: 800Mi
      requests:
        cpu: 100m
        memory: 100Mi
EOF
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

  # patch as Downstream to scrape metrics
  oc patch csv/$CSV -n openshift-netobserv-operator --type='json' -p='[{"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/3/value", "value": "true"}]'

  if [[ $PATCH_EBPFAGENT_IMAGE ]]; then
    PATCH="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/0/value\", \"value\": \"$PATCH_EBPFAGENT_IMAGE\"}]"
      oc patch csv/$CSV -n openshift-netobserv-operator --type='json' -p="$PATCH"
  fi 

  if [[ $PATCH_FLOWLOGS_IMAGE ]]; then
      PATCH="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/1/value\", \"value\": \"$PATCH_FLOWLOGS_IMAGE\"}]"
      oc patch csv/$CSV -n openshift-netobserv-operator --type='json' -p="$PATCH"
  fi

  if [[ $PATCH_CONSOLE_PLUGIN_IMAGE ]]; then
      PATCH="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/2/value\", \"value\": \"$PATCH_CONSOLE_PLUGIN_IMAGE\"}]"
      oc patch csv/$CSV -n openshift-netobserv-operator --type='json' -p="$PATCH"
  fi

  if [[ $PATCH_OPERATOR_IMAGE ]]; then
      PATCH="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"$PATCH_OPERATOR_IMAGE\"}]"
      oc patch csv/$CSV -n openshift-netobserv-operator --type='json' -p="$PATCH"
  fi
}

if [[ "$CATALOG_SOURCE" == "source" ]]; then
    echo "====> Using upstream catalog bundle with tag: vmain"
    CATALOG_IMAGE="quay.io/netobserv/network-observability-operator-catalog:v0.0.0-main"
    CATALOG_NAME="netobserv-main"
    CHANNEL="latest" # for upstream catalog source "latest" is the channel name.
    deploy_catalog
fi

NAMESPACE=netobserv
oc new-project ${NAMESPACE} || true

echo "====> Deploying 0-click Loki"
oc apply -f https://raw.githubusercontent.com/netobserv/documents/main/examples/zero-click-loki/1-storage.yaml -n ${NAMESPACE}
oc apply -f https://raw.githubusercontent.com/netobserv/documents/main/examples/zero-click-loki/2-loki.yaml -n ${NAMESPACE}

sleep 30
oc wait --timeout=180s --for=condition=ready pod -l olm.catalogSource=$CATALOG_NAME -n openshift-marketplace

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

sleep 10
update_flowcollector
oc apply -f $FLOWCOLLECTOR

sleep 30
echo "====> Waiting for flowlogs-pipeline daemonset to be created"
while :; do
    oc get daemonset flowlogs-pipeline -n ${NAMESPACE} && break
    sleep 1
done

echo "====> Waiting for netobserv-ebpf-agent daemonset to be created"
while :; do
    oc get daemonset netobserv-ebpf-agent -n ${NAMESPACE}-privileged && break
    sleep 1
done

echo "====> Waiting for console-plugin deployment to be created"
while :; do
    oc get deployment netobserv-plugin -n ${NAMESPACE} && break
    sleep 1
done

echo "====> Waiting for flowcollector to be ready"
timeout=0
while [ $timeout -lt 180 ]; do
    oc get flowcollector/cluster | grep Ready && break
    sleep 30
    timeout=$((timeout+30))
done
