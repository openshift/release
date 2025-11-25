#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

: "${NAMESPACE:=netobserv}"

update_flowcollector() {
  FLOWCOLLECTOR=/tmp/flowcollector.yaml
  cat <<EOF >$FLOWCOLLECTOR
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
spec:
  namespace: netobserv
  deploymentModel: Direct
  networkPolicy:
    enable: true
    additionalNamespaces: []
  agent:
    type: eBPF
    ebpf:
      imagePullPolicy: IfNotPresent
      logLevel: info
      sampling: 50
      cacheActiveTimeout: 5s
      cacheMaxFlows: 100000
      # Change privileged to "true" on old kernel version not knowing CAP_BPF or when using "PacketDrop" feature
      privileged: false  
      interfaces: []
      excludeInterfaces: ["lo"] 
      metrics:
        server:
          port: 9400
      # Custom optionnal resources configuration
      resources:
        requests:
          memory: 50Mi
          cpu: 100m
        limits:
          memory: 800Mi
  processor:
    imagePullPolicy: IfNotPresent
    logLevel: info
    logTypes: Flows
    metrics:
      server:
        port: 9401
      disableAlerts: []
    # Custom optionnal resources configuration
    resources:
      requests:
        memory: 100Mi
        cpu: 100m
      limits:
        memory: 800Mi
  loki:
    enable: true
    # Change mode to "LokiStack" to use with the loki operator
    mode: Monolithic
    monolithic:
      url: 'http://loki.netobserv.svc:3100/'
      tenantID: netobserv
      tls:
        enable: false
        caCert:
          type: configmap
          name: loki-gateway-ca-bundle
          certFile: service-ca.crt
    lokiStack:
      name: loki
    readTimeout: 30s
    # Write stage configuration
    writeTimeout: 10s
    writeBatchWait: 1s
    writeBatchSize: 10485760
  prometheus:
    querier:
      enable: true
      mode: Auto
      timeout: 30s
  consolePlugin:
    enable: true
    imagePullPolicy: IfNotPresent
    logLevel: info
    # Scaling configuration
    replicas: 1
    autoscaler:
      status: Disabled
      minReplicas: 1
      maxReplicas: 3
      metrics:
      - type: Resource
        resource:
          name: cpu
          target:
            type: Utilization
            averageUtilization: 50
    # Custom optionnal port-to-service name translation
    portNaming:
      enable: true
      portNames:
        "3100": loki
    # Custom optionnal filter presets
    quickFilters:
    - name: Applications
      filter:
        flow_layer: '"app"'
      default: true
    - name: Infrastructure
      filter:
        flow_layer: '"infra"'
    - name: Pods network
      filter:
        src_kind: '"Pod"'
        dst_kind: '"Pod"'
      default: true
    - name: Services network
      filter:
        dst_kind: '"Service"'
    # Custom optionnal resources configuration
    resources:
      requests:
        memory: 50Mi
        cpu: 100m
      limits:
        memory: 100Mi
  exporters: []
EOF
}

echo "====> Creating FlowCollector"
update_flowcollector
oc apply -f $FLOWCOLLECTOR

echo "====> Waiting for FlowCollector to be ready"
timeout=0
rc=1
while [ $timeout -lt 300 ]; do
  status=$(oc get flowcollector/cluster -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "")
  if [[ "$status" == "Ready" ]]; then
    rc=0
    break
  fi
  sleep 10
  timeout=$((timeout+10))
done

if [ "${rc}" == 1 ]; then
  echo "====> FlowCollector did not become Ready after 300 seconds"
  oc get flowcollector/cluster -o yaml || true
  exit $rc
fi

echo "====> FlowCollector is ready"

echo "====> Waiting for flowlogs-pipeline daemonset to be created"
timeout=0
while [ $timeout -lt 120 ]; do
  oc get daemonset flowlogs-pipeline -n ${NAMESPACE} >/dev/null 2>&1 && break
  sleep 5
  timeout=$((timeout+5))
done

if oc get daemonset flowlogs-pipeline -n ${NAMESPACE} >/dev/null 2>&1; then
  echo "====> flowlogs-pipeline daemonset created"
else
  echo "====> Warning: flowlogs-pipeline daemonset not found after 120 seconds"
fi

echo "====> Waiting for netobserv-ebpf-agent daemonset to be created"
timeout=0
while [ $timeout -lt 120 ]; do
  oc get daemonset netobserv-ebpf-agent -n ${NAMESPACE}-privileged >/dev/null 2>&1 && break
  sleep 5
  timeout=$((timeout+5))
done

if oc get daemonset netobserv-ebpf-agent -n ${NAMESPACE}-privileged >/dev/null 2>&1; then
  echo "====> netobserv-ebpf-agent daemonset created"
else
  echo "====> Warning: netobserv-ebpf-agent daemonset not found after 120 seconds"
fi

echo "====> Waiting for console-plugin deployment to be created"
timeout=0
while [ $timeout -lt 120 ]; do
  oc get deployment netobserv-plugin -n ${NAMESPACE} >/dev/null 2>&1 && break
  sleep 5
  timeout=$((timeout+5))
done

if oc get deployment netobserv-plugin -n ${NAMESPACE} >/dev/null 2>&1; then
  echo "====> netobserv-plugin deployment created"
else
  echo "====> Warning: netobserv-plugin deployment not found after 120 seconds"
fi

