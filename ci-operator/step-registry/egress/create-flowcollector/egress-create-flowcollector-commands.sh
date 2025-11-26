#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

: "${NAMESPACE:=netobserv}"

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
  loki:
    enable: true
    lokiStack:
      name: loki
    mode: Monolithic
  namespace: ${NAMESPACE}
  processor:
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

echo "====> Creating FlowCollector"
update_flowcollector
oc apply -f $FLOWCOLLECTOR

sleep 30
echo "====> Waiting for flowlogs-pipeline daemonset to be created"
while :; do
  oc get daemonset flowlogs-pipeline -n ${NAMESPACE} && break
  sleep 1
done

echo "====> Waiting for console-plugin deployment to be created"
while :; do
  oc get deployment netobserv-plugin -n ${NAMESPACE} && break
  sleep 1
done

echo "====> Waiting for flowcollector to be ready"
timeout=0
rc=1
while [ $timeout -lt 180 ]; do
  status=$(oc get flowcollector/cluster -o jsonpath='{.status.conditions[0].reason}')
  if [[ $status == "Ready" ]]; then
    rc=0
    break
  fi
  sleep 30
  timeout=$((timeout+30))
done
if [ "${rc}" == 1 ]; then
  echo "flowcollector did not become Ready after 180 secs!!!"
  exit $rc
fi

echo "====> FlowCollector creation completed successfully"

# Reset namespace context to avoid CI system trying to create secrets in netobserv namespace
oc project default >/dev/null 2>&1 || true