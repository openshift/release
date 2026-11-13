#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MCE=${MCE_VERSION:-""}
CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
if [[ -n ${MCE} ]] ; then
    CLUSTER_NAMESPACE_PREFIX=local-cluster
else
    CLUSTER_NAMESPACE_PREFIX=clusters
fi
CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}

# dump_vm_debug_logs collects kubelet/crio logs from inside KubeVirt VMs via SSH.
# The --generate-ssh flag used during cluster creation stores the private key in
# a secret named <cluster-name>-ssh-key with data key "id_rsa".
dump_vm_debug_logs() {
  echo "Collecting VM-level debug logs..."
  local ssh_key="/tmp/hc-ssh-key"
  local ssh_secret="${CLUSTER_NAME}-ssh-key"

  if ! oc get secret -n "${CLUSTER_NAMESPACE_PREFIX}" "${ssh_secret}" &>/dev/null; then
    echo "SSH key secret ${ssh_secret} not found, skipping VM debug log collection"
    return
  fi

  oc get secret -n "${CLUSTER_NAMESPACE_PREFIX}" "${ssh_secret}" \
    -o jsonpath='{.data.id_rsa}' | base64 -d > "${ssh_key}" 2>/dev/null
  if [[ ! -s "${ssh_key}" ]]; then
    echo "SSH private key is empty, skipping VM debug log collection"
    rm -f "${ssh_key}"
    return
  fi
  chmod 600 "${ssh_key}"

  for VMI in $(oc get vmi -n "${CLUSTER_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "Collecting debug logs from VMI ${VMI}..."
    local vm_log="${ARTIFACT_DIR}/vm-debug-${VMI}.log"

    local vmi_ip
    vmi_ip=$(oc get vmi -n "${CLUSTER_NAMESPACE}" "${VMI}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
    if [[ -z "${vmi_ip}" ]]; then
      echo "Could not determine IP for VMI ${VMI}, skipping SSH"
    else
      ssh -i "${ssh_key}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "core@${vmi_ip}" \
        "sudo journalctl -u kubelet --no-pager -n 200 2>&1; \
         echo '=== crio ===' ; \
         sudo journalctl -u crio --no-pager -n 100 2>&1; \
         echo '=== containers ===' ; \
         sudo crictl ps -a 2>&1; \
         echo '=== systemctl failed ===' ; \
         sudo systemctl list-units --state=failed 2>&1" \
        > "${vm_log}" 2>&1 || true
    fi

    if [[ -s "${vm_log}" ]]; then
      echo "Saved VM debug logs to ${vm_log}"
    else
      echo "No SSH logs collected from VMI ${VMI}, falling back to console-logger"
      rm -f "${vm_log}"
    fi

    # Always capture console-logger output as a fallback
    local console_pod="${VMI}-console-logger"
    oc logs -n "${CLUSTER_NAMESPACE}" "${console_pod}" \
      > "${ARTIFACT_DIR}/vm-console-${VMI}.log" 2>/dev/null || true
  done

  rm -f "${ssh_key}"
  echo "VM debug log collection complete"
}

echo "Waiting for nested cluster's node count to reach the desired replicas count in the NodePool"
if [[ -n "${HYPERSHIFT_KUBEVIRT_NODE_JOIN_TIMEOUT:-}" ]]; then
  NODE_JOIN_TIMEOUT_SECONDS="${HYPERSHIFT_KUBEVIRT_NODE_JOIN_TIMEOUT}"
elif [[ "${ATTACH_DEFAULT_NETWORK:-}" == "localnet-multi" ]]; then
  # localnet-multi workers bootstrap slower (OVN DHCP, guest routing, MCD pull).
  NODE_JOIN_TIMEOUT_SECONDS=3600
else
  NODE_JOIN_TIMEOUT_SECONDS=1800
fi
echo "Node join timeout: ${NODE_JOIN_TIMEOUT_SECONDS}s (ATTACH_DEFAULT_NETWORK=${ATTACH_DEFAULT_NETWORK:-})"
WAIT_TIMEOUT=$(($(date +%s) + NODE_JOIN_TIMEOUT_SECONDS))
until \
  [[ $(oc get nodepool "${CLUSTER_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "") \
    == $(oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers 2>/dev/null | wc -l) ]]; do
      if [[ $(date +%s) -ge ${WAIT_TIMEOUT} ]]; then
        echo "Timed out waiting for node count to match NodePool replicas after $((NODE_JOIN_TIMEOUT_SECONDS / 60)) minutes"
        dump_vm_debug_logs
        exit 1
      fi
      echo "$(date --rfc-3339=seconds) Nested cluster's node count is not equal to the desired replicas in the NodePool. Retrying in 30 seconds."
      oc get vmi -n "${CLUSTER_NAMESPACE}" 2>/dev/null || true
      sleep 30s
done

echo "Waiting for clusteroperators to be ready"
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null;  do
    echo "$(date --rfc-3339=seconds) Cluster Operators not yet ready"
    oc get clusteroperators 2>/dev/null || true
    sleep 1s
done

if [[ -n ${MCE} ]] ; then
    echo "Waiting for ManagedCluster to be ready"
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
    until \
    oc wait managedcluster "${CLUSTER_NAME}" --for='condition=ManagedClusterJoined' >/dev/null && \
    oc wait managedcluster "${CLUSTER_NAME}" --for='condition=ManagedClusterConditionAvailable' >/dev/null && \
    oc wait managedcluster "${CLUSTER_NAME}" --for='condition=HubAcceptedManagedCluster' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) ManagedCluster not yet ready"
    sleep 10s
    done
fi