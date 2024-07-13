#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-worker metal3 command ************"

source "${SHARED_DIR}/packet-conf.sh"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -o=jsonpath="{.items[?(@.metadata.name=='$CLUSTER_NAME')].metadata.namespace}")
HOSTED_CONTROL_PLANE_NAMESPACE=${HOSTED_CLUSTER_NS}"-"${CLUSTER_NAME}

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$CLUSTER_NAME" "$HOSTED_CONTROL_PLANE_NAMESPACE" "$EXTRA_BAREMETALHOSTS_FILE" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1
set -xeo pipefail
CLUSTER_NAME="${1}"
HOSTED_CONTROL_PLANE_NAMESPACE="${2}"
EXTRA_BAREMETALHOSTS_FILE="${3}"

SSH_PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
cat <<END | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
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
  namespace: '${HOSTED_CONTROL_PLANE_NAMESPACE}'
type: Opaque
data:
  username: '${driver_info_username}'
  password: '${driver_info_password}'
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: '${host_name}'
  namespace: '${HOSTED_CONTROL_PLANE_NAMESPACE}'
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
set +e
while true; do
    count=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers --ignore-not-found | wc -l)
    if [ ${count} == ${NUM_EXTRA_WORKERS} ] ; then
        echo "agent resources already exist"
        break
    fi
    echo "Waiting on agent resources create"
    sleep 60
done
set -e
oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE}  --for=condition=RequirementsMet

echo "scale nodepool replicas => $NUM_EXTRA_WORKERS"
oc scale nodepool ${CLUSTER_NAME} -n $(oc get hostedcluster -A -o=jsonpath="{.items[?(@.metadata.name=='$CLUSTER_NAME')].metadata.namespace}") --replicas ${NUM_EXTRA_WORKERS}
echo "wait agent ready"
oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=30m
EOF

oc get InfraEnv -n ${HOSTED_CONTROL_PLANE_NAMESPACE} ${CLUSTER_NAME} -o yaml > "${ARTIFACT_DIR}/InfraEnv.yaml"
oc get BareMetalHost -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o yaml > "${ARTIFACT_DIR}/extra_baremetalhosts.yaml"