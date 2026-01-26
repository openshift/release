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

function gather() {
  oc get InfraEnv -n ${AGENT_NAMESPACE} ${CLUSTER_NAME} -o yaml > "${ARTIFACT_DIR}/InfraEnv.yaml"
  oc get BareMetalHost -n ${AGENT_NAMESPACE} -o yaml > "${ARTIFACT_DIR}/extra_baremetalhosts.yaml"
}

trap gather EXIT

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$CLUSTER_NAME" "$AGENT_NAMESPACE" "$EXTRA_BAREMETALHOSTS_FILE" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g' &
# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1
set -xeo pipefail
CLUSTER_NAME="${1}"
AGENT_NAMESPACE="${2}"
EXTRA_BAREMETALHOSTS_FILE="${3}"

oc get ns "${AGENT_NAMESPACE}" || oc create namespace "${AGENT_NAMESPACE}"
if ! oc get secret pull-secret -n "${AGENT_NAMESPACE}"; then
    oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
    oc create secret generic pull-secret --from-file=.dockerconfigjson=/tmp/.dockerconfigjson --type=kubernetes.io/dockerconfigjson -n "${AGENT_NAMESPACE}"
fi

SSH_PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
cat <<END | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${AGENT_NAMESPACE}
spec:
  ignitionConfigOverride: |
    {
      "ignition": {"version": "3.2.0"},
      "systemd": {
        "units": [{
          "name": "NetworkManager-wait-online.service",
          "dropins": [{
            "name": "timeout.conf",
            "contents": "[Service]\nEnvironment=NM_ONLINE_TIMEOUT=180\n"
          }]
        }]
      }
    }
  cpuArchitecture: x86_64
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: "${SSH_PUB_KEY}"
END
oc wait --for=condition=ImageCreated infraenv/${CLUSTER_NAME} -n ${AGENT_NAMESPACE} --timeout=5m

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
    disableCertificateVerification: true
END
done < <(jq -c '.[]' ${EXTRA_BAREMETALHOSTS_FILE})

source ~/dev-scripts-additional-config
set +e
while true; do
    count=$(oc get agent -n ${AGENT_NAMESPACE} --no-headers --ignore-not-found | wc -l)
    if [ ${count} == ${NUM_EXTRA_WORKERS} ] ; then
        echo "agent resources already exist"
        break
    fi
    echo "Waiting on agent resources create"
    sleep 60
done
set -e
oc wait --all=true agent -n ${AGENT_NAMESPACE}  --for=condition=RequirementsMet

echo "scale nodepool replicas => $NUM_EXTRA_WORKERS"
oc scale nodepool ${CLUSTER_NAME} -n $(oc get hostedcluster -A -o=jsonpath="{.items[?(@.metadata.name=='$CLUSTER_NAME')].metadata.namespace}") --replicas ${NUM_EXTRA_WORKERS}
echo "wait agent ready"
oc wait --all=true agent -n ${AGENT_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=30m
EOF

# Running the previous ssh command in background and waiting for it here
# allows catching the SIGTERM signal immediately, even if the ssh command
# runs indefinitely.
# See https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_11
wait
