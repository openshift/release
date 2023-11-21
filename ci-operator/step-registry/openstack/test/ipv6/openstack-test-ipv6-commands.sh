#!/usr/bin/env bash

set -Eeuo pipefail

function wait_for_network() {
    # Wait up to 2 minutes for the network to be ready
    for _ in $(seq 1 12); do
        NETWORK_ATTACHMENT_DEFINITIONS=$(oc get network-attachment-definitions "${ADDITIONAL_NETWORK}" -n "${IPV6_NAMESPACE}" -o jsonpath='{.metadata.name}' || true)
        if [ "${NETWORK_ATTACHMENT_DEFINITIONS}" == "${ADDITIONAL_NETWORK}" ]; then
            FOUND_NAD=1
            break
        fi
        echo "Waiting for network ${ADDITIONAL_NETWORK} to be attached"
        sleep 10
    done

    if [ -n "${FOUND_NAD:-}" ] ; then
        echo "Network ${ADDITIONAL_NETWORK} is attached"
    else
        echo "Network ${ADDITIONAL_NETWORK} is not attached after two minutes"
        oc get network-attachment-definitions "${ADDITIONAL_NETWORK}" -n "${IPV6_NAMESPACE}" -o jsonpath='{.metadata.name}'
        exit 1
    fi
}

function check_pod_status() {
    INTERVAL=30
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
        done <<< "$(oc -n "${IPV6_NAMESPACE}" get pods "${IPV6_POD}" --no-headers)"

        if [[ "${READY}" == "true" ]]; then
            echo "Pod ${IPV6_POD} has successfully been deployed"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Pod ${IPV6_POD} did not successfully deploy"
            oc -n "${IPV6_NAMESPACE}" get pods
            return 1
        fi
    done
}

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

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

IPV6_NAMESPACE="ipv6-slaac"
oc new-project "${IPV6_NAMESPACE}"
echo "Created ${IPV6_NAMESPACE} Namespace"


cat <<EOF > "${SHARED_DIR}/additionalnetwork-ipv6.yaml"
spec:
  additionalNetworks:
  - name: ${ADDITIONAL_NETWORK}
    namespace: ${IPV6_NAMESPACE}
    rawCNIConfig: '{ "cniVersion": "0.3.1", "name": "${ADDITIONAL_NETWORK}", "type": "macvlan", "master": "ens4"}'
    type: Raw
EOF

oc patch network.operator cluster --patch "$(cat "${SHARED_DIR}/additionalnetwork-ipv6.yaml")" --type=merge
wait_for_network

WORKER_IPV6_PORTS=$(openstack port list --network "${ADDITIONAL_NETWORK}" --tags cluster-api-provider-openstack -c Name -f value)
WORKERS=$(oc get nodes --selector=node-role.kubernetes.io/worker -o custom-columns=NAME:.metadata.name --no-headers)

for i in $(seq 1 2); do

PORT_NAME=$(echo $WORKER_IPV6_PORTS | cut -f $i -d " ")
openstack port set --no-security-group --disable-port-security $PORT_NAME

WORKER_NAME=$(echo $WORKERS | cut -f $i -d " ")
echo $WORKER_NAME
IPV6_POD=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pod-$i
  namespace: ${IPV6_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/networks: ${ADDITIONAL_NETWORK}
spec:
  nodeName: ${WORKER_NAME}
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - image: quay.io/kuryr/demo
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
    imagePullPolicy: Always
    name: demo
EOF
)
echo "Created ipv6 Pod ${IPV6_POD}"
check_pod_status
done

POD1_IPV6_ADDRESS=$(oc rsh -n "${IPV6_NAMESPACE}" pod-1 ip -6 addr show dev net1 scope global |  awk '/inet6/{print $2}' | cut -f1 -d"/")

echo "Attempting to connect to ${POD1_IPV6_ADDRESS}"

CONNECTION_OUTPUT=$(oc rsh -n "${IPV6_NAMESPACE}" "${IPV6_POD}" curl ["${POD1_IPV6_ADDRESS}"]:8080)
echo $CONNECTION_OUTPUT
if [[ "${CONNECTION_OUTPUT}" == *"HELLO"* ]]; then
    echo "Successfuly connected from Pod-2 to Pod-1"
else
    echo "Unable to connect from Pod-2 to Pod-1"
fi

echo "Cleaning ${IPV6_NAMESPACE} namespace"
oc delete namespace "${IPV6_NAMESPACE}"

echo "Removing additionalNetworks from network.operator"
oc patch network.operator cluster --patch '{"spec":{"additionalNetworks": []}}' --type=merge

echo "Successfully ran IPv6 test as additional network"
