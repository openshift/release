#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, can not continue."
	exit 0
fi

# Download jq
mkdir /tmp/bin
export PATH=$PATH:/tmp/bin
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
chmod ug+x /tmp/bin/jq

# Create infra machineconfigpool
oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: infra
  labels:
    operator.machineconfiguration.openshift.io/required-for-upgrade: ''
spec:
  machineConfigSelector:
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,infra]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/infra: ""
EOF

# Get machineset name to generate a generic template
ref_machineset_name=$(oc -n openshift-machine-api get -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' machinesets | grep worker | head -n1)

# Replace machine name worker to infra
infra_machineset_name="${ref_machineset_name/worker/infra}"

export ref_machineset_name infra_machineset_name
# Get a templated json from worker machineset, change machine type and machine name
# and pass it to oc to create a new machine set
oc get machineset $ref_machineset_name -n openshift-machine-api -o json |
  jq --arg infra_node_type "${INFRA_NODE_TYPE}" \
     --arg infra_machineset_name "${infra_machineset_name}" \
     '
      .metadata.name = $infra_machineset_name |
      .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $infra_machineset_name |
      .spec.template.spec.providerSpec.value.instanceType = $infra_node_type |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $infra_machineset_name |
      .spec.template.spec.metadata.labels."node-role.kubernetes.io/infra" = "" |
      del(.status) |
      del(.metadata.selfLink) |
      del(.metadata.uid)
     ' | oc create -f -

# Scale machineset to expected number of replicas
oc -n openshift-machine-api scale machineset/"${infra_machineset_name}" --replicas="${INFRA_NODE_REPLICAS}"

echo "Waiting for infra nodes to come up"
while [[ $(oc -n openshift-machine-api get machineset/${infra_machineset_name} -o 'jsonpath={.status.readyReplicas}') != "${INFRA_NODE_REPLICAS}" ]]; do echo -n "." && sleep 5; done

# Collect infra node names
mapfile -t INFRA_NODE_NAMES < <(echo "$(oc get nodes -l node-role.kubernetes.io/infra -o name)" | sed 's;node\/;;g')
echo "Infra nodes ${INFRA_NODE_NAMES[*]} are up"

echo "Moving routers to infra nodes"
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  nodePlacement:
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/infra: ""
EOF

INGRESS_PODS_MOVED="false"
for i in $(seq 0 60); do
  echo "Checking ingress pods, attempt ${i}"
  mapfile -t INGRESS_NODES < <(oc get pods -n openshift-ingress -o jsonpath='{.items[*].spec.nodeName}')
  if [[ -z "$(echo "${INGRESS_NODES[@]}" "${INFRA_NODE_NAMES[@]}" | tr ' ' '\n' | sort | uniq -u)" ]]; then
    INGRESS_PODS_MOVED="true"
    echo "Ingress pods moved to infra nodes"
    break
  else
    sleep 10
  fi
done
if [[ "${INGRESS_PODS_MOVED}" == "false" ]]; then
  echo "Ingress pods didn't move to infra nodes"
  exit 1
fi

echo "Moving registry pods to infra nodes"
oc apply -f - <<EOF
apiVersion: imageregistry.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - podAffinityTerm:
          namespaces:
          - openshift-image-registry
          topologyKey: kubernetes.io/hostname
        weight: 100
  nodeSelector:
    node-role.kubernetes.io/infra: ""
EOF
REGISTRY_PODS_MOVED="false"
for i in $(seq 0 60); do
  echo "Checking registry pods, attempt ${i}"
  mapfile -t REGISTRY_NODES < <(oc get pods -n openshift-image-registry -l docker-registry=default -o jsonpath='{.items[*].spec.nodeName}')
  if [[ -z "$(echo "${REGISTRY_NODES[@]}" "${INFRA_NODE_NAMES[@]}" | tr ' ' '\n' | sort | uniq -u)" ]]; then
    REGISTRY_PODS_MOVED="true"
    echo "Registry pods moved to infra nodes"
    break
  else
    sleep 10
  fi
done
if [[ "${REGISTRY_PODS_MOVED}" == "false" ]]; then
  echo "Image registry pods didn't move to infra nodes"
  exit 1
fi

echo "Moving monitoring pods to infra nodes"
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    alertmanagerMain:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    grafana:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    metricsServer:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
EOF

MONITORING_PODS_MOVED="false"
for i in $(seq 0 60); do
  echo "Checking monitoring pods, attempt ${i}"
  mapfile -t MONITORING_NODES < <(oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/component=alert-router)
  if [[ -z "$(echo "${MONITORING_NODES[@]}" "${INFRA_NODE_NAMES[@]}" | tr ' ' '\n' | sort | uniq -u)" ]]; then
    MONITORING_PODS_MOVED="true"
    echo "Monitoring pods moved to infra nodes"
    break
  else
    sleep 10
  fi
done
if [[ "${MONITORING_PODS_MOVED}" == "false" ]]; then
  echo "Monitoring pods didn't move to infra nodes"
  exit 1
fi

echo "Waiting for all pods to settle"
sleep 5
while [[ $(oc get pods --no-headers -A | grep -Pv "(Completed|Running)" | wc -l) != "0" ]]; do echo -n "." && sleep 5; done
