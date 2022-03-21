#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# SOURCE_NAMESPACE="egressip-source"
TARGET_NAMESPACE="egressip-target"
# EGRESSIP_NAME="egressip-source"
SOURCE_LABEL="node-role.kubernetes.io/egressip-test-source"
TARGET_LABEL="node-role.kubernetes.io/egressip-test-target"
TARGET_TAINT="egressip-test-target"
EGRESS_ASSIGNABLE_LABEL="k8s.ovn.org/egress-assignable"
# https://docs.openshift.com/container-platform/4.10/installing/installing_aws/installing-restricted-networks-aws.html#installation-cloudformation-security_installing-restricted-networks-aws
TARGET_PORT="32767"

is_command() {
  local cmd="$1"
  if ! command -v ${cmd} &> /dev/null
  then
    echo "Command '${cmd} could not be found"
    exit 1
  fi
}

for cmd in wc jq oc mktemp; do
  is_command $cmd
done

#############################################
# label EgressIP target and source nodes
#############################################

nodes=$(oc get nodes -l node-role.kubernetes.io/worker= -o name)
if [ "$(echo $nodes | wc -w)" -lt 3 ] ; then
  echo "Not enough worker nodes - at least 3 worker nodes are required. Got: $nodes"
  exit 1
fi

echo "Labelling worker nodes with ${SOURCE_LABEL} and ${TARGET_LABEL}"
i=0
for n in $nodes; do
  if [ $i -eq 0 ]; then
    echo "Labelling node $n with label ${TARGET_LABEL}"
    oc label $n ${TARGET_LABEL}=
  else
    echo "Labelling node $n with label ${SOURCE_LABEL}"
    oc label $n ${SOURCE_LABEL}=
  fi
  i=$((i+1))
done

oc get nodes

#############################################
# Apply NoExecute taint to target nodes
#############################################

echo "Applying target NoExecute taint to target nodes"
nodes=$(oc get nodes -l ${TARGET_LABEL}= -o name)
if [ "$(echo $nodes | wc -w)" -lt 1 ] ; then
  echo "Not enough worker nodes with label ${TARGET_LABEL} - at least 1 worker node is required. Got: $nodes"
  exit 1
fi

i=0
for n in $nodes; do
  oc adm taint node $n ${TARGET_TAINT}=true:NoExecute --overwrite
done

#############################################
# Apply egress assignable label to nodes
#############################################

echo "Applying egress assignable label ${EGRESS_ASSIGNABLE_LABEL} to nodes"
nodes=$(oc get nodes -l ${SOURCE_LABEL}= -o name)
if [ "$(echo $nodes | wc -w)" -lt 2 ] ; then
  echo "Not enough worker nodes with label ${SOURCE_LABEL} - at least 2 worker nodes are required. Got: $nodes"
  exit 1
fi

i=0
for n in $nodes; do
  oc label $n ${EGRESS_ASSIGNABLE_LABEL}="" --overwrite
done

oc get nodes -l k8s.ovn.org/egress-assignable=""

#############################################
# Create target namespace and pod
#############################################

file=$(mktemp)
cat <<EOF > ${file}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${TARGET_NAMESPACE}
  labels:
    env: ${TARGET_NAMESPACE}
---
apiVersion: apps/v1
kind: "DaemonSet"
metadata:
  labels:
    app: ${TARGET_NAMESPACE}-deployment
  name: ${TARGET_NAMESPACE}-deployment
  namespace: ${TARGET_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: ${TARGET_NAMESPACE}-deployment
  template:
    metadata:
      labels:
        app: ${TARGET_NAMESPACE}-deployment
    spec:
      hostNetwork: true
      nodeSelector:
        ${TARGET_LABEL}: ""
      tolerations:
        - key: ${TARGET_TAINT}
          operator: Exists
      containers:
      - command:
        - "/agnhost"
        - "netexec"
        - "--http-port"
        - "${TARGET_PORT}"
        image: k8s.gcr.io/e2e-test-images/agnhost:2.33
        imagePullPolicy: IfNotPresent
        name: agnhost
EOF
oc apply -f ${file}

oc adm policy add-scc-to-user hostnetwork -z default -n ${TARGET_NAMESPACE}

oc get pods -n ${TARGET_NAMESPACE} -o wide

