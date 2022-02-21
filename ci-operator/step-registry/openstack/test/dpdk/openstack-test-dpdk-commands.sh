#!/usr/bin/env bash

set -Eeuo pipefail

function check_pod_status() {
    INTERVAL=60
    CNT=10
    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            pod_name=$(echo "${i}" | awk '{print $1}')
            pod_phase=$(echo "${i}" | awk '{print $3}')
            if [[ "${pod_phase}" == "Running" ]]; then
                READY=true
            else
                echo "Waiting for Pod ${pod_name} to be ready"
                READY=false
            fi
        done <<< "$(oc -n "${CNF_NAMESPACE}" get pods "${CNF_POD}" --no-headers)"

        if [[ "${READY}" == "true" ]]; then
            echo "Pod ${CNF_POD} has successfully been deployed"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Pod ${CNF_POD} did not successfully deploy"
            oc -n "${CNF_NAMESPACE}" get pods "${CNF_POD}"
            return 1
        fi
    done
}

CNF_NAMESPACE="example-cnf-dpdk"
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

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

CNF_NAMESPACE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CNF_NAMESPACE}
EOF
)
echo "Created \"$CNF_NAMESPACE\" Namespace"

if ! openstack network show "${OPENSTACK_DPDK_NETWORK}" >/dev/null 2>&1; then
    echo "Network ${OPENSTACK_DPDK_NETWORK} doesn't exist"
    exit 1
fi

cat <<EOF > "${SHARED_DIR}/additionalnetwork.yaml"
spec:
  additionalNetworks:
  - name: ${OPENSTACK_DPDK_NETWORK}
    namespace: ${CNF_NAMESPACE}
    rawCNIConfig: '{ "cniVersion": "0.3.1", "name": "${OPENSTACK_DPDK_NETWORK}", "type": "host-device","pciBusId": "0000:00:04.0", "ipam": {}}'
    type: Raw
EOF
oc patch network.operator cluster --patch "$(cat "${SHARED_DIR}/additionalnetwork.yaml")" --type=merge
# Give the operator some time to apply the patch
sleep 5

NETWORK_ATTACHED=$(oc get network-attachment-definitions "${OPENSTACK_DPDK_NETWORK}" -n "${CNF_NAMESPACE}" -o jsonpath='{.metadata.name}')
if [[ "${NETWORK_ATTACHED}" == "${OPENSTACK_DPDK_NETWORK}" ]]; then
    echo "Successfully Added additional network to the Network Operator"
else
    echo "Failed to add additional network to the Network Operator"
    echo "${NETWORK_ATTACHED}"
    exit 1
fi

CNF_POD=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: testpmd-host-device-dpdk
  namespace: ${CNF_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/networks: ${OPENSTACK_DPDK_NETWORK}
spec:
  containers:
  - name: testpmd
    command: ["sleep", "99999"]
    image: registry.redhat.io/openshift4/dpdk-base-rhel8:v4.9
    securityContext:
      capabilities:
        add: ["IPC_LOCK","SYS_ADMIN"]
      privileged: true
      runAsUser: 0
    resources:
      requests:
        memory: 1000Mi
        hugepages-1Gi: 1Gi
        cpu: '2'
      limits:
        hugepages-1Gi: 1Gi
        cpu: '2'
        memory: 1000Mi
    volumeMounts:
      - mountPath: /dev/hugepages
        name: hugepage
        readOnly: False
  volumes:
  - name: hugepage
    emptyDir:
      medium: HugePages
EOF
)

check_pod_status

POD_AFFINITY=$(oc -n "${CNF_NAMESPACE}" rsh "${CNF_POD}" taskset -pc 1)
if [[ "${POD_AFFINITY}" == *"pid 1's current affinity list: 2"* ]]; then
    echo "Pod's affinity is correctly set to 2"
else
    echo "Error when checking Pod's affinity"
    echo "${POD_AFFINITY}"
    oc -n "${CNF_NAMESPACE}" get pods "${CNF_POD}"
    exit 1
fi

TESTPMD_OUTPUT=$(oc -n "${CNF_NAMESPACE}" rsh "${CNF_POD}" bash -c "yes | testpmd -l 2-3 --in-memory -w 00:04.0 --socket-mem 1024 -n 4 --proc-type auto --file-prefix pg  -- --disable-rss  --nb-cores=1 --rxq=1 --txq=1 --auto-start --forward-mode=mac")
echo "${TESTPMD_OUTPUT}"
if [[ "${TESTPMD_OUTPUT}" == *"forwards packets on 1 streams"* ]]; then
    echo "Testpmd could run successfully"
else
    echo "Testpmd did not run successfully"
    exit 1
fi

echo "Cleaning ${CNF_NAMESPACE} namespace"
oc delete namespace "${CNF_NAMESPACE}"

echo "Removing additionalNetworks from network.operator"
oc patch network.operator cluster --patch '{"spec":{"additionalNetworks": []}}' --type=merge

echo "Successfully ran NFV DPDK tests"
