#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

wait_for_sriov_pods() {
    # Wait up to 15 minutes for SNO to be installed
    for _ in $(seq 1 15); do
        SNO_REPLICAS=$(oc get Deployment/sriov-network-operator -n openshift-sriov-network-operator -o jsonpath='{.status.readyReplicas}' || true)
        if [ "${SNO_REPLICAS}" == "1" ]; then
            FOUND_SNO=1
            break
        fi
        echo "Waiting for sriov-network-operator to be installed"
        sleep 60
    done

    if [ -n "${FOUND_SNO:-}" ] ; then
        # Wait for the pods to be started from the operator
        for _ in $(seq 1 8); do
            NOT_RUNNING_PODS=$(oc get pods --no-headers -n openshift-sriov-network-operator | grep -Pv "(Completed|Running)" | wc -l || true)
            if [ "${NOT_RUNNING_PODS}" == "0" ]; then
                OPERATOR_READY=true
                break
            fi
            echo "Waiting for sriov-network-operator pods to be started and running"
            sleep 30
        done
        if [ -n "${OPERATOR_READY:-}" ] ; then
            echo "sriov-network-operator pods were installed successfully"
        else
            echo "sriov-network-operator pods were not installed after 4 minutes"
            oc get pods -n openshift-sriov-network-operator
            exit 1
        fi
    else
        echo "sriov-network-operator was not installed after 15 minutes"
        exit 1
    fi
}

wait_for_webhook() {
  # Even if the pods are ready, we need to wait for the webhook server to be
  # actually started, which usually takes a few seconds.
  for _ in $(seq 1 30); do
      WEBHOOK_NAME=$(oc get validatingwebhookconfigurations.admissionregistration.k8s.io  sriov-operator-webhook-config -o jsonpath='{.metadata.name}')
      if [ "${WEBHOOK_NAME}" == "sriov-operator-webhook-config" ]; then
          WEBHOOK_READY=true
          break
      fi
      echo "Waiting for webhook pods to be running"
      sleep 2
  done

  if [ -n "${WEBHOOK_READY:-}" ] ; then
      echo "webhook started succesfully"
  else
      echo "webhook did not start succesfully"
      exit 1
  fi
}

create_sriov_networknodepolicy() {
    local name="${1}"
    local network="${2}"
    local driver="${3}"
    local is_rdma="${4}"

    if ! openstack network show "${network}" >/dev/null 2>&1; then
        echo "Network ${network} doesn't exist"
        exit 1
    fi
    net_id=$(openstack network show "${network}" -f value -c id)

    SRIOV_NETWORKNODEPOLICY=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: ${name}
  namespace: openshift-sriov-network-operator
spec:
  deviceType: ${driver} 
  isRdma: ${is_rdma}
  nicSelector:
    netFilter: openstack/NetworkID:${net_id}
  nodeSelector:
    feature.node.kubernetes.io/network-sriov.capable: 'true'
  numVfs: 1
  priority: 99
  resourceName: ${name}
EOF
    )
    echo "Created \"$SRIOV_NETWORKNODEPOLICY\" SriovNetworkNodePolicy"
}

if ! test -f "${SHARED_DIR}/sriov-worker-node"; then
  echo "${SHARED_DIR}/sriov-worker-node file not found, no worker node for SR-IOV was deployed"
  exit 1
fi

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

wait_for_sriov_pods

WEBHOOK_ENABLED=$(oc get sriovoperatorconfig/default -n openshift-sriov-network-operator -o jsonpath='{.spec.enableOperatorWebhook}')
if [ "${WEBHOOK_ENABLED}" == true ]; then
  wait_for_webhook
fi

if [[ "${OPENSTACK_SRIOV_NETWORK}" == *"mellanox"* ]]; then
    SRIOV_DEVICE_TYPE="netdevice"
    IS_RDMA="true"
else
    SRIOV_DEVICE_TYPE="vfio-pci"
    IS_RDMA="false"
fi

echo "Print SriovNetworkNodeState before creating SriovNetworkNodePolicy"
oc get SriovNetworkNodeState -n openshift-sriov-network-operator -o yaml

create_sriov_networknodepolicy "sriov1" "${OPENSTACK_SRIOV_NETWORK}" "${SRIOV_DEVICE_TYPE}" "${IS_RDMA}"

if [[ "${OPENSTACK_DPDK_NETWORK}" != "" ]]; then
    if oc get MachineConfig/99-vhostuser-bind >/dev/null 2>&1; then
        echo "vhostuser is already bound to the ${OPENSTACK_DPDK_NETWORK} network."
        exit 0
    fi
    create_sriov_networknodepolicy "dpdk1" "${OPENSTACK_DPDK_NETWORK}" "vfio-pci" "false"
fi
