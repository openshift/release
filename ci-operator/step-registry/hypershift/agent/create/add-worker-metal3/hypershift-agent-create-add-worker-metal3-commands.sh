#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-worker metal3 command ************"

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -o=jsonpath="{.items[?(@.metadata.name=='$CLUSTER_NAME')].metadata.namespace}")
if [[ -z ${AGENT_NAMESPACE} ]] ; then
  AGENT_NAMESPACE=${HOSTED_CLUSTER_NS}"-"${CLUSTER_NAME}
fi
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$CLUSTER_NAME" "$AGENT_NAMESPACE" "$EXTRA_BAREMETALHOSTS_FILE" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -x
CLUSTER_NAME="${1}"
AGENT_NAMESPACE="${2}"
EXTRA_BAREMETALHOSTS_FILE="${3}"

SSH_PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
cat <<END | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${AGENT_NAMESPACE}
spec:
  cpuArchitecture: x86_64
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
END

while IFS= read -r host; do
    host_name=$(echo "$host" | jq -r '.name')
    driver_info_username=$(echo "$host" | jq -r '.driver_info.username' | base64)
    driver_info_password=$(echo "$host" | jq -r '.driver_info.password' | base64)
    driver_info_address=$(echo "$host" | jq -r '.driver_info.address')
    bootMACAddress=$(echo "$host" | jq -r '.ports[0].address')
    cat <<END | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: '${host_name}-bmc-secret'
  namespace: '${AGENT_NAMESPACE}'
type: Opaque
data:
  username: '${driver_info_username}'
  password: '${driver_info_password}'
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: '${host_name}'
  namespace: '${AGENT_NAMESPACE}'
  labels:
    infraenvs.agent-install.openshift.io: '${CLUSTER_NAME}'
  annotations:
    bmac.agent-install.openshift.io/hostname: '${host_name}'
spec:
  online: true
  bootMACAddress: '${bootMACAddress}'
  bmc:
    address: '${driver_info_address}'
    credentialsName: '${host_name}-bmc-secret'
END
done < <(jq -c '.[]' ${EXTRA_BAREMETALHOSTS_FILE})

source ~/dev-scripts-additional-config
_agentExist=0
set +e
for ((i=1; i<=20; i++)); do
    count=$(oc get agent -n ${AGENT_NAMESPACE} --no-headers --ignore-not-found | wc -l)
    if [ ${count} == ${NUM_EXTRA_WORKERS} ]  ; then
        echo "agent resources already exist"
        _agentExist=1
        break
    fi
    echo "Waiting on agent resources create"
    sleep 60
done
set -e
if [ $_agentExist -eq 0 ]; then
  echo "FATAL: agent cr not Exist"
  exit 1
fi
oc wait --all=true agent -n ${AGENT_NAMESPACE}  --for=condition=RequirementsMet

echo "scale nodepool replicas => $NUM_EXTRA_WORKERS"
oc scale nodepool ${HOSTED_CLUSTER_NAME} -n $(oc get hostedcluster -A -o=jsonpath="{.items[?(@.metadata.name=='$CLUSTER_NAME')].metadata.namespace}") --replicas ${NUM_EXTRA_WORKERS}
echo "wait agent ready"
oc wait --all=true agent -n ${AGENT_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=45m
EOF