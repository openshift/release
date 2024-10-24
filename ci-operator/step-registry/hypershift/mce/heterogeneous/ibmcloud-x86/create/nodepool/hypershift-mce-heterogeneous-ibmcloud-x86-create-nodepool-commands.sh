#!/bin/bash

set -x

# Agent hosted cluster configs
CLUSTERS_NAMESPACE="local-cluster"
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# InfraEnv configs
SSH_PUB_KEY_FILE="${AGENT_POWER_CREDENTIALS}/ssh-publickey"
SSH_PUB_KEY=$(cat ${SSH_PUB_KEY_FILE})
export SSH_PUB_KEY

# Installing required tools
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

# Updating AgentServiceConfig with x86 osImages
CLUSTER_VERSION=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
OS_IMAGES=$(jq --arg CLUSTER_VERSION "${CLUSTER_VERSION}" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' "${SHARED_DIR}/default_os_images.json")
# shellcheck disable=SC2034
VERSION=$(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "x86_64").version')
# shellcheck disable=SC2034
URL=$(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "x86_64").url')
echo "$(date) Updating AgentServiceConfig"
oc patch AgentServiceConfig agent --type=json -p="[{\"op\": \"add\", \"path\": \"/spec/osImages/-\", \"value\": {\"openshiftVersion\": \"${CLUSTER_VERSION}\", \"version\": \"${VERSION}\", \"url\": \"${URL}\",  \"cpuArchitecture\": \"x86_64\"}}]"
oc get AgentServiceConfig agent -o yaml

oc wait --timeout=5m --for=condition=DeploymentsHealthy agentserviceconfig agent
echo "$(date) AgentServiceConfig updated"

# Creating nodepool for x86
echo "$(date) Creating Nodepool on x86_64 architecture"
cat <<EOF | oc create -f -
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: ${HOSTED_CLUSTER_NAME}-x86
  namespace: ${CLUSTERS_NAMESPACE}
spec:
  arch: amd64
  clusterName: ${HOSTED_CLUSTER_NAME}
  management:
    autoRepair: false
    upgradeType: InPlace
  nodeDrainTimeout: 0s
  platform:
    agent:
      agentLabelSelector:
        matchLabels:
          inventory.agent-install.openshift.io/cpu-architecture: x86_64
    type: Agent
  release:
    image: ${OCP_IMAGE_MULTI}
  replicas: 0
EOF

# Applying InfraEnv for x86
echo "$(date) Applying InfraEnv for x86_64 architecture"
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}-x86
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
spec:
  cpuArchitecture: x86_64
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF

#oc patch ingresscontroller default -n openshift-ingress-operator -p '{"spec": {"nodePlacement": {"nodeSelector": { "matchLabels": { "node-role.kubernetes.io/worker": ""}}}}}' --type=merge --kubeconfig=${SHARED_DIR}/nested_kubeconfig
oc patch ingresscontroller default -n openshift-ingress-operator \
-p '{"spec": {"replicas": 4, "nodePlacement": {"nodeSelector": { "matchLabels": { "node-role.kubernetes.io/worker": ""}}}}}' \
--type=merge --kubeconfig=${SHARED_DIR}/nested_kubeconfig
