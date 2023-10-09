#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

function wait_for_network() {
    # Wait up to 2 minutes for the network to be ready
    for _ in $(seq 1 12); do
        NETWORK_ATTACHMENT_DEFINITIONS=$(oc get network-attachment-definitions "${OPENSTACK_DPDK_NETWORK}" -n "${CNF_NAMESPACE}" -o jsonpath='{.metadata.name}' || true)
        if [ "${NETWORK_ATTACHMENT_DEFINITIONS}" == "${OPENSTACK_DPDK_NETWORK}" ]; then
            FOUND_NAD=1
            break
        fi
        echo "Waiting for network ${OPENSTACK_DPDK_NETWORK} to be attached"
        sleep 10
    done

    if [ -n "${FOUND_NAD:-}" ] ; then
        echo "Network ${OPENSTACK_DPDK_NETWORK} is attached"
    else
        echo "Network ${OPENSTACK_DPDK_NETWORK} is not attached after two minutes"
        oc get network-attachment-definitions "${OPENSTACK_DPDK_NETWORK}" -n "${CNF_NAMESPACE}" -o jsonpath='{.metadata.name}'
        exit 1
    fi
}

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

if [[ ${OPENSTACK_DPDK_NETWORK} == "" ]]; then
    echo "OPENSTACK_DPDK_NETWORK is not set, skipping the test"
    exit 0
fi

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

OPENSTACK_DPDK_NETWORK_ID=$(openstack network show "${OPENSTACK_DPDK_NETWORK}" -f value -c id)
DPDK_PCI_DEVICE=$(oc get sriovnetworknodestates -n openshift-sriov-network-operator -o jsonpath='{.items[0].status.interfaces[?(@.netFilter=="'"openstack/NetworkID:${OPENSTACK_DPDK_NETWORK_ID}"'")].pciAddress}')

CNF_NAMESPACE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CNF_NAMESPACE}
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/audit: "privileged"
    pod-security.kubernetes.io/enforce: "privileged"
    pod-security.kubernetes.io/warn: "privileged"
EOF
)
echo "Created \"$CNF_NAMESPACE\" Namespace"

if oc get SriovNetworkNodePolicy/dpdk1 -n openshift-sriov-network-operator >/dev/null 2>&1; then
    echo "DPDK network is managed by SriovNetworkNodePolicy/dpdk1, CNI won't be changed"
    RESOURCE_REQUEST="openshift.io/dpdk1: \"1\""
else
    if ! openstack network show "${OPENSTACK_DPDK_NETWORK}" >/dev/null 2>&1; then
        echo "Network ${OPENSTACK_DPDK_NETWORK} doesn't exist"
        exit 1
    fi
    
    cat <<EOF > "${SHARED_DIR}/additionalnetwork-dpdk.yaml"
spec:
  additionalNetworks:
  - name: ${OPENSTACK_DPDK_NETWORK}
    namespace: ${CNF_NAMESPACE}
    rawCNIConfig: '{ "cniVersion": "0.3.1", "name": "${OPENSTACK_DPDK_NETWORK}", "type": "host-device","pciBusId": "${DPDK_PCI_DEVICE}", "ipam": {}}'
    type: Raw
EOF
    oc patch network.operator cluster --patch "$(cat "${SHARED_DIR}/additionalnetwork-dpdk.yaml")" --type=merge
    wait_for_network
    ANNOTATIONS="k8s.v1.cni.cncf.io/networks: ${OPENSTACK_DPDK_NETWORK}"
fi

CNF_POD=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: testpmd-host-device-dpdk
  namespace: ${CNF_NAMESPACE}
  annotations:
    cpu-load-balancing.crio.io: "disable"
    cpu-quota.crio.io: "disable"
    ${ANNOTATIONS:-}
spec:
  runtimeClassName: performance-cnf-performanceprofile
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
        ${RESOURCE_REQUEST:-}
      limits:
        hugepages-1Gi: 1Gi
        cpu: '2'
        memory: 1000Mi
        ${RESOURCE_REQUEST:-}
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

TESTPMD_OUTPUT=$(oc -n "${CNF_NAMESPACE}" rsh "${CNF_POD}" bash -c "yes | testpmd -l 2-3 --in-memory --allow ${DPDK_PCI_DEVICE} --socket-mem 1024 -n 4 --proc-type auto --file-prefix pg  -- --disable-rss  --nb-cores=1 --rxq=1 --txq=1 --auto-start --forward-mode=mac")
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
