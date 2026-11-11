#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

VALIDATION_FAILED=0

# Pod-health namespaces are stable across platforms since the CCM/CSI migration;
# the cloud-conf ConfigMap name/namespace below is lower-confidence and checked
# best-effort only (see its section).
CCM_NAMESPACE="openshift-cloud-controller-manager"
CSI_NAMESPACE="openshift-cluster-csi-drivers"

check_pods_running() {
  local namespace=$1

  echo "$(date -u --rfc-3339=seconds) - Checking pod health in namespace ${namespace}..."
  local pods_json
  if ! pods_json=$(oc get pods -n "${namespace}" -o json 2>&1); then
    echo "$(date -u --rfc-3339=seconds) - ERROR: failed to list pods in ${namespace}"
    echo "${pods_json}"
    VALIDATION_FAILED=1
    return
  fi

  local pod_count
  pod_count=$(jq -r '.items | length' <<< "${pods_json}")
  if [[ "${pod_count}" -eq 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: no pods found in ${namespace}"
    VALIDATION_FAILED=1
    return
  fi

  local not_ready
  # A pod with no containerStatuses (e.g. still initializing) is treated as
  # not ready too, rather than vacuously passing because no container was
  # found to be explicitly not-ready.
  not_ready=$(jq -r '
    .items[] |
    select(
      .status.phase != "Running" or
      ((.status.containerStatuses // []) | length == 0) or
      ((.status.containerStatuses // []) | any(.ready == false))
    ) |
    .metadata.name' <<< "${pods_json}")

  if [[ -n "${not_ready}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: unhealthy pod(s) in ${namespace}:"
    echo "${not_ready}"
    VALIDATION_FAILED=1
  else
    echo "$(date -u --rfc-3339=seconds) - all pods in ${namespace} are Running and Ready"
  fi
}

echo "$(date -u --rfc-3339=seconds) - Confirming the Infrastructure CR has no vSphere failure domain data..."
# This job exists specifically to exercise code against a legacy-shaped
# Infrastructure CR; if the simulation stopped applying (e.g. the installer
# started rejecting the stripped manifest, or STRIP_VSPHERE_FAILURE_DOMAINS
# was dropped from the job), every other check below would be validating the
# wrong thing. A failed read here must not be treated the same as a
# successful read of an empty field -- that would hide the read failure
# behind a false "confirmed empty" pass.
INFRA_READ_FAILED=0
if ! VCENTERS=$(oc get infrastructure cluster -o jsonpath='{.spec.platformSpec.vsphere.vcenters}' 2>&1); then
  echo "$(date -u --rfc-3339=seconds) - ERROR: failed to read spec.platformSpec.vsphere.vcenters from the Infrastructure CR"
  echo "${VCENTERS}"
  INFRA_READ_FAILED=1
  VCENTERS=""
fi
if ! FAILURE_DOMAINS=$(oc get infrastructure cluster -o jsonpath='{.spec.platformSpec.vsphere.failureDomains}' 2>&1); then
  echo "$(date -u --rfc-3339=seconds) - ERROR: failed to read spec.platformSpec.vsphere.failureDomains from the Infrastructure CR"
  echo "${FAILURE_DOMAINS}"
  INFRA_READ_FAILED=1
  FAILURE_DOMAINS=""
fi

if [[ ${INFRA_READ_FAILED} -ne 0 ]]; then
  VALIDATION_FAILED=1
elif [[ -n "${VCENTERS}" || -n "${FAILURE_DOMAINS}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: expected spec.platformSpec.vsphere.vcenters and .failureDomains to be empty, found:"
  echo "  vcenters: ${VCENTERS}"
  echo "  failureDomains: ${FAILURE_DOMAINS}"
  VALIDATION_FAILED=1
else
  echo "$(date -u --rfc-3339=seconds) - confirmed: vcenters and failureDomains are both empty"
fi

echo "$(date -u --rfc-3339=seconds) - Checking ClusterOperator health..."
# console is checked as a coarse signal only: a Degraded/unavailable console
# operator would indicate a real problem, but the known regression class here
# (OCPBUGS-90834/35321, blank vSphere connection details in the console UI) is
# a client-side rendering bug that does NOT flip this condition. Confirming the
# UI itself needs a browser-level test, which is out of scope for this step.
for CO in storage cloud-controller-manager console; do
  AVAILABLE=$(oc get clusteroperator "${CO}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>&1) || AVAILABLE="MISSING"
  DEGRADED=$(oc get clusteroperator "${CO}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>&1) || DEGRADED="MISSING"
  if [[ "${AVAILABLE}" != "True" || "${DEGRADED}" != "False" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: clusteroperator/${CO} Available=${AVAILABLE} Degraded=${DEGRADED}"
    VALIDATION_FAILED=1
  else
    echo "$(date -u --rfc-3339=seconds) - clusteroperator/${CO} is healthy"
  fi
done

check_pods_running "${CCM_NAMESPACE}"
check_pods_running "${CSI_NAMESPACE}"

echo "$(date -u --rfc-3339=seconds) - Scanning cloud-controller-manager logs for the OCPBUGS-136178 regression signature..."
# Iterate every pod rather than relying on a specific label selector, since
# the exact CCM pod labels are lower-confidence than the namespace name.
# Each pod's log is scanned immediately (bounded by --tail) instead of being
# concatenated into one growing variable, and matched with a plain bash
# substring test instead of piping into `grep -q`: with `pipefail`, a `grep
# -q` consumer that stops reading after an early match can SIGPIPE the writer
# on the other end of the pipe, which turns into a spurious pipeline failure
# (and a missed detection) once there is enough log data after the match.
CCM_LOG_READ_FAILED=0
CCM_SIGNATURE_FOUND=0
if ! ccm_pod_names=$(oc get pods -n "${CCM_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>&1); then
  echo "$(date -u --rfc-3339=seconds) - ERROR: failed to list pods in ${CCM_NAMESPACE} for the log scan"
  echo "${ccm_pod_names}"
  CCM_LOG_READ_FAILED=1
  ccm_pod_names=""
elif [[ -z "${ccm_pod_names}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: no pods found in ${CCM_NAMESPACE} to scan for the OCPBUGS-136178 regression signature"
  CCM_LOG_READ_FAILED=1
fi

for pod in ${ccm_pod_names}; do
  if ! pod_logs=$(oc logs -n "${CCM_NAMESPACE}" "${pod}" --all-containers --tail=10000 2>&1); then
    echo "$(date -u --rfc-3339=seconds) - ERROR: failed to read logs for CCM pod ${pod}"
    echo "${pod_logs}"
    CCM_LOG_READ_FAILED=1
    continue
  fi
  if [[ "${pod_logs}" == *"No Virtual Center hosts defined"* ]]; then
    CCM_SIGNATURE_FOUND=1
  fi
done

if [[ ${CCM_LOG_READ_FAILED} -ne 0 ]]; then
  VALIDATION_FAILED=1
fi

if [[ ${CCM_SIGNATURE_FOUND} -ne 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: found 'No Virtual Center hosts defined' in CCM logs (OCPBUGS-136178 regression signature)"
  VALIDATION_FAILED=1
else
  echo "$(date -u --rfc-3339=seconds) - no OCPBUGS-136178 regression signature found in CCM logs"
fi

# Best-effort only: the cloud-conf ConfigMap's exact name/namespace is lower
# confidence than the checks above, so its absence is a warning, not a hard
# failure, to avoid false negatives from an incorrect assumption here.
echo "$(date -u --rfc-3339=seconds) - (best-effort) Checking cloud-conf ConfigMap for vCenter sections..."
CLOUD_CONF=$(oc get configmap cloud-conf -n "${CCM_NAMESPACE}" -o jsonpath='{.data.cloud\.conf}' 2>&1) || CLOUD_CONF=""
if [[ -z "${CLOUD_CONF}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - WARNING: could not read cloud-conf ConfigMap data.cloud.conf in ${CCM_NAMESPACE}; skipping this best-effort check"
elif ! grep -q '^\[VirtualCenter' <<< "${CLOUD_CONF}"; then
  echo "$(date -u --rfc-3339=seconds) - WARNING: cloud-conf has no [VirtualCenter ...] section (OCPBUGS-136178 symptom); not failing the job on this best-effort check, but worth investigating:"
  echo "${CLOUD_CONF}"
else
  echo "$(date -u --rfc-3339=seconds) - cloud-conf contains a [VirtualCenter ...] section"
fi

if [[ ${VALIDATION_FAILED} -eq 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - legacy vSphere Infrastructure CR validation: PASSED"
  exit 0
else
  echo "$(date -u --rfc-3339=seconds) - legacy vSphere Infrastructure CR validation: FAILED"
  exit 1
fi
