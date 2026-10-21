#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# Disable xtrace: proxy-conf.sh may export HTTP_PROXY with embedded credentials.
	set +x
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
	set -x
fi

if test -f "${SHARED_DIR}/packet-conf.sh"
then
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/packet-conf.sh"
fi

LVM_CLUSTER_MANIFEST="${SHARED_DIR}/lvm-cluster.yaml"

# Use the same namespace as the operator installation, or auto-detect if not set
if [[ -z "${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  # Auto-detect namespace based on cluster version
  CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
  MINOR_VERSION=$(echo $CLUSTER_VERSION | cut -d. -f2)

  echo "Detected OpenShift version: ${CLUSTER_VERSION}"

  # For OpenShift 4.20+, use openshift-lvm-storage, otherwise use openshift-storage
  if [[ ${MINOR_VERSION} -ge 20 ]]; then
    LVM_NAMESPACE="openshift-lvm-storage"
  else
    LVM_NAMESPACE="openshift-storage"
  fi

  echo "Auto-detected LVM namespace: ${LVM_NAMESPACE}"
else
  LVM_NAMESPACE="${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
  echo "Using operator namespace: ${LVM_NAMESPACE}"
fi

cat <<EOF > "$LVM_CLUSTER_MANIFEST"
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: ${LVM_NAMESPACE}
spec:
  storage:
    deviceClasses:
    - name: vg1
      default: true
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
EOF

if [ "$LVM_CLUSTER_AUTO_SELECT_AVAILABLE_DEVICES" == "true" ]; then
    echo "Using auto-selecting available LVM devices mode ..."
else
    echo "LVM auto-selection is disabled ..."
    yq eval ".spec.storage.deviceClasses[0].deviceSelector.paths[0] = \"${LVM_CLUSTER_DEVICE_PATH}\"" -i "$LVM_CLUSTER_MANIFEST"
fi

if [ "$LVM_CLUSTER_WIPE_DEVICE" == "true" ]; then
    echo "Enabling forceWipeDevicesAndDestroyAllData mode ..."
    yq eval ".spec.storage.deviceClasses[0].deviceSelector.forceWipeDevicesAndDestroyAllData = ${LVM_CLUSTER_WIPE_DEVICE}" -i "$LVM_CLUSTER_MANIFEST"
fi

# Conditionally add tolerations for master/control-plane nodes
if [ "$LVM_CLUSTER_TOLERATE_MASTER" == "true" ]; then
    echo "Enabling lvm storage on master nodes ..."
    yq eval '.spec.tolerations = [{"key": "node-role.kubernetes.io/master", "operator": "Exists", "effect": "NoSchedule"}]' -i "$LVM_CLUSTER_MANIFEST"
fi

oc apply -f "$LVM_CLUSTER_MANIFEST"

echo "Create lvmcluster successfully, waiting for it to become usable (max 10min)."

# We gate on *functional* readiness rather than only LVMCluster .status.state.
#
# On LVMS <= 4.13, getExpectedVgCount counts every node (incl. control-plane)
# when the LVMCluster has no nodeSelector, so on multi-node clusters the
# aggregate .status.state stays "Progressing" forever even though the volume
# groups are created and storage works. That status field is cosmetic (nothing
# in the product consumes it; it is fixed from 4.14 on), so gating purely on it
# makes this shared step fail on 4.12/4.13 baselines for no real reason.
#
# Instead we accept the cluster once it is actually usable, which is correct for
# every release: the vg-manager and topolvm-node DaemonSets are fully rolled out
# AND every per-node volume group reports Ready (and none Failed/Degraded). We
# still honour .status.state == Ready as a fast path for healthy 4.14+ clusters.
lvmcluster_ready() {
  local ns="${1}"

  # Fast path: operator reports Ready (always correct on 4.14+).
  if [[ "$(oc get lvmcluster -n "${ns}" -o=jsonpath='{.items[0].status.state}' 2>/dev/null)" == "Ready" ]]; then
    return 0
  fi

  # Operand DaemonSets must be fully rolled out.
  local ds desired ready_count
  for ds in vg-manager topolvm-node; do
    desired=$(oc get daemonset "${ds}" -n "${ns}" -o=jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    ready_count=$(oc get daemonset "${ds}" -n "${ns}" -o=jsonpath='{.status.numberReady}' 2>/dev/null)
    if [[ -z "${desired}" || "${desired}" -eq 0 || "${desired}" != "${ready_count}" ]]; then
      return 1
    fi
  done

  # Per-node volume-group statuses: one "status" line per VG per node.
  local vg_states total_vgs ready_vgs bad_vgs vg_desired
  vg_states=$(oc get lvmvolumegroupnodestatus -n "${ns}" \
    -o=jsonpath='{range .items[*]}{range .spec.nodeStatus[*]}{.status}{"\n"}{end}{end}' 2>/dev/null)
  total_vgs=$(printf '%s\n' "${vg_states}" | grep -c . || true)
  ready_vgs=$(printf '%s\n' "${vg_states}" | grep -cx 'Ready' || true)
  bad_vgs=$(printf '%s\n' "${vg_states}" | grep -cxE 'Failed|Degraded' || true)

  # vg-manager runs one pod per targeted (worker) node; every such node must
  # report a Ready volume group, with none Failed/Degraded.
  vg_desired=$(oc get daemonset vg-manager -n "${ns}" -o=jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
  vg_desired=${vg_desired:-0}
  if [[ "${total_vgs}" -gt 0 && "${bad_vgs}" -eq 0 && "${ready_vgs}" -eq "${total_vgs}" && "${ready_vgs}" -ge "${vg_desired}" ]]; then
    return 0
  fi

  return 1
}

iter=10
period=60
ready="false"
while [[ ${iter} -gt 0 ]]; do
  if lvmcluster_ready "${LVM_NAMESPACE}"; then
    ready="true"
    break
  fi
  (( iter -- ))
  sleep $period
done

if [ "${ready}" == "true" ]; then
  echo "LVM cluster is functionally ready."
  oc get lvmcluster -n "${LVM_NAMESPACE}" -o wide 2>/dev/null || true
else
  echo "Failed to set up lvm cluster."
  oc describe lvmcluster -n "${LVM_NAMESPACE}"
  oc get lvmvolumegroupnodestatus -n "${LVM_NAMESPACE}" -o yaml || true
  oc get daemonset -n "${LVM_NAMESPACE}" || true
  for pod in $(oc get pods -n "${LVM_NAMESPACE}" --no-headers | grep -Ev "Running|Completed" | awk '{print $1}')
  do
    echo "This is describe info of pod ${pod}"
    oc -n "${LVM_NAMESPACE}" describe pod "${pod}"
  done
  exit 1
fi
