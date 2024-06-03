#!/bin/bash

set -x

# Agent hosted cluster configs
CLUSTERS_NAMESPACE="local-cluster"
HOSTED_CLUSTER_NAME="$(printf "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# InfraEnv configs
SSH_PUB_KEY_FILE="${AGENT_POWER_CREDENTIALS}/ssh-publickey"
SSH_PUB_KEY=$(cat "${SSH_PUB_KEY_FILE}")
export SSH_PUB_KEY

create_nodepool() {
  NAME_SUFFIX="$1"
  CPU_ARCH="$2"
  ARCH="$3"

  NP_NAME="${HOSTED_CLUSTER_NAME}-${NAME_SUFFIX}"
  echo "$(date) Creating additional Nodepool ${NP_NAME}"
  cat <<EOF | oc create -f -
  apiVersion: hypershift.openshift.io/v1beta1
  kind: NodePool
  metadata:
    name: ${NP_NAME}
    namespace: ${CLUSTERS_NAMESPACE}
  spec:
    arch: ${ARCH}
    clusterName: ${HOSTED_CLUSTER_NAME}
    management:
      autoRepair: false
      upgradeType: InPlace
    nodeDrainTimeout: 0s
    platform:
      agent:
        agentLabelSelector:
          matchLabels:
            inventory.agent-install.openshift.io/cpu-architecture: ${CPU_ARCH}
      type: Agent
    release:
      image: ${OCP_IMAGE_MULTI}
    replicas: 0
EOF
}

create_infraenv() {
  NAME_SUFFIX="$1"
  CPU_ARCH="$2"
  INFRA_NAME="${HOSTED_CLUSTER_NAME}-${NAME_SUFFIX}"
  echo "$(date) Applying InfraEnv ${INFRA_NAME}"
  envsubst <<EOF | oc apply -f -
  apiVersion: agent-install.openshift.io/v1beta1
  kind: InfraEnv
  metadata:
    name: ${INFRA_NAME}
    namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
  spec:
    cpuArchitecture: ${CPU_ARCH}
    pullSecretRef:
      name: pull-secret
    sshAuthorizedKey: ${SSH_PUB_KEY}
EOF
}

# Read additional nodepool details
IFS=$'\n' read -d '' -r -a config_lines <<< "${ADDITIONAL_HYPERSHIFT_NODEPOOL_CONFIG}"

for line in "${config_lines[@]}"; do
    IFS=', ' read -r NAME_SUFFIX CPU_ARCH NODE_ARCH <<< "${line}"
    if [[ "${NODE_ARCH}" == "ppc64le" ]]; then
      MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
      if (( $(echo "${MCE_VERSION} < 2.6" | bc -l) )); then
        # Support for using ppc64le arch added after MCE 2.6
        NODE_ARCH="amd64"
      fi
    fi
    create_nodepool "${NAME_SUFFIX}" "${CPU_ARCH}" "${NODE_ARCH}"
    create_infraenv "${NAME_SUFFIX}" "${CPU_ARCH}"
done
