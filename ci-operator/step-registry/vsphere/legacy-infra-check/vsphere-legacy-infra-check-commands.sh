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
  # One line per pod: "<name> <phase> <ready>,<ready>,..." -- parsed with
  # plain bash below. Deliberately no jq: this step runs from the cli image,
  # which does not ship it (a rehearsal failed with "jq: command not found",
  # exit 127). jsonpath is served by oc itself, so it is always present.
  local pods
  if ! pods=$(oc get pods -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.containerStatuses[*]}{.ready}{","}{end}{"\n"}{end}' 2>&1); then
    echo "$(date -u --rfc-3339=seconds) - ERROR: failed to list pods in ${namespace}"
    echo "${pods}"
    VALIDATION_FAILED=1
    return
  fi

  if [[ -z "${pods//[[:space:]]/}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: no pods found in ${namespace}"
    VALIDATION_FAILED=1
    return
  fi

  local not_ready=""
  local name phase readies
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    name=""
    phase=""
    readies=""
    read -r name phase readies <<< "${line}"
    # A pod with no containerStatuses (e.g. still initializing) arrives with
    # an empty readies list and is treated as not ready too, rather than
    # vacuously passing because no container was found to be explicitly
    # not-ready.
    if [[ "${phase}" != "Running" || -z "${readies//,/}" || "${readies}" == *false* ]]; then
      not_ready+="${name}"$'\n'
    fi
  done <<< "${pods}"

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

SWAP_ORDER="${VSPHERE_LEGACY_CLOUD_CONFIG_SWAP_ORDER:-post-bootstrap}"

echo "$(date -u --rfc-3339=seconds) - Checking the VSphereMultiVCenterDay2 feature gate state..."
# This is the authoritative signal for whether the install step picked the
# right swap ordering: the gate decides who owns
# openshift-config-managed/kube-cloud-config (verbatim CCO copy while off,
# CCMO-normalized YAML once on), and that decides the format of the in-cluster
# render the bootstrap render has to match.
#
# status.featureGates is only populated in-cluster (cluster-config-operator's
# featuregate controller), one entry per payload version, each with explicit
# enabled[]/disabled[] lists -- so this cannot be consulted during bootstrap,
# only afterwards, which is why the install step still selects the mode from
# its pin and this step verifies it.
FG_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>&1) || FG_VERSION=""
FG_DUMP=$(oc get featuregate cluster -o jsonpath='{range .status.featureGates[*]}{.version}{"|"}{range .enabled[*]}{.name}{","}{end}{"|"}{range .disabled[*]}{.name}{","}{end}{"\n"}{end}' 2>&1) || FG_DUMP=""

FG_GATE_STATE="unknown"
FG_MATCHED_VERSION=""
if [[ -z "${FG_DUMP//[[:space:]]/}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - WARNING: could not read status.featureGates from featuregate/cluster; skipping the gate-state check"
else
  while IFS='|' read -r fg_ver fg_enabled fg_disabled; do
    [[ -z "${fg_ver//[[:space:]]/}" ]] && continue
    # Prefer the entry for the version the cluster is actually running; fall
    # back to the last entry (the controller appends per payload version) when
    # none matches, which happens while a version change is in flight.
    if [[ "${fg_ver}" == "${FG_VERSION}" || -z "${FG_MATCHED_VERSION}" || "${FG_MATCHED_VERSION}" != "${FG_VERSION}" ]]; then
      FG_MATCHED_VERSION="${fg_ver}"
      case ",${fg_enabled}," in
        *",VSphereMultiVCenterDay2,"*) FG_GATE_STATE="enabled" ;;
        *)
          case ",${fg_disabled}," in
            *",VSphereMultiVCenterDay2,"*) FG_GATE_STATE="disabled" ;;
            *) FG_GATE_STATE="not-listed" ;;
          esac ;;
      esac
    fi
  done <<< "${FG_DUMP}"
  echo "  VSphereMultiVCenterDay2 (payload ${FG_MATCHED_VERSION}, cluster ${FG_VERSION:-unknown}) : ${FG_GATE_STATE}"
fi

# Expected: gate disabled => cluster-config-operator owns the managed copy and
# copies it verbatim, so the manifest must have been INI at render time
# (pre-bootstrap). Gate enabled => CCMO normalizes it to YAML, so the manifest
# had to stay the installer's YAML (post-bootstrap). A contradiction here is a
# warning, not a failure: the job's purpose is the cluster's health, and when
# the ordering is genuinely wrong the install dies before this step runs.
case "${SWAP_ORDER}:${FG_GATE_STATE}" in
  pre-bootstrap:enabled)
    echo "$(date -u --rfc-3339=seconds) - WARNING: swap order is pre-bootstrap (assumes VSphereMultiVCenterDay2 disabled) but the gate is ENABLED on this payload; set VSPHERE_LEGACY_CLOUD_CONFIG_SWAP_ORDER=post-bootstrap for this release line"
    ;;
  post-bootstrap:disabled)
    echo "$(date -u --rfc-3339=seconds) - WARNING: swap order is post-bootstrap (assumes VSphereMultiVCenterDay2 enabled) but the gate is DISABLED on this payload; set VSPHERE_LEGACY_CLOUD_CONFIG_SWAP_ORDER=pre-bootstrap for this release line"
    ;;
  *:not-listed)
    echo "$(date -u --rfc-3339=seconds) - WARNING: VSphereMultiVCenterDay2 is not listed in the enabled/disabled sets for payload ${FG_MATCHED_VERSION}; this payload may predate the gate, so the swap order cannot be verified"
    ;;
esac

echo "$(date -u --rfc-3339=seconds) - Checking the cloud-provider-config carrier formats..."
# The simulation is only meaningful if openshift-config holds the legacy INI,
# and the *in-cluster* consumer reads openshift-config-managed/kube-cloud-config
# (MCO's syncCloudConfig). The gate check above is the authoritative statement
# of which format that copy should have; this table corroborates it and shows
# the ControllerConfig MCO actually derived. A mismatch between managed and the
# expected format is reported as a warning rather than a failure: when the
# ordering is genuinely wrong the bootstrap/in-cluster MachineConfig hashes
# diverge and the install itself dies first. The exception is the unmanaged
# ConfigMap, which the job exists to produce and which is therefore a hard
# failure.
UNMANAGED_CC=$(oc get configmap cloud-provider-config -n openshift-config -o jsonpath='{.data.config}' 2>&1) || UNMANAGED_CC=""
MANAGED_CC=$(oc get configmap kube-cloud-config -n openshift-config-managed -o jsonpath='{.data.cloud\.conf}' 2>&1) || MANAGED_CC=""
CONTROLLER_CC=$(oc get controllerconfig machine-config-controller -o jsonpath='{.spec.cloudProviderConfig}' 2>&1) || CONTROLLER_CC=""

describe_cc_format() {
  local value=$1
  if [[ -z "${value}" ]]; then echo "absent"; return; fi
  if [[ "${value}" =~ ^[[:space:]]*\[ ]]; then echo "INI"; return; fi
  if grep -qE '^[[:space:]]*(global|vcenter):' <<< "${value}"; then echo "YAML"; return; fi
  echo "unknown"
}

UNMANAGED_FORMAT=$(describe_cc_format "${UNMANAGED_CC}")
MANAGED_FORMAT=$(describe_cc_format "${MANAGED_CC}")
CONTROLLER_FORMAT=$(describe_cc_format "${CONTROLLER_CC}")
echo "  openshift-config/cloud-provider-config          : ${UNMANAGED_FORMAT}"
echo "  openshift-config-managed/kube-cloud-config     : ${MANAGED_FORMAT}"
echo "  ControllerConfig.spec.cloudProviderConfig      : ${CONTROLLER_FORMAT}"
echo "  VSPHERE_LEGACY_CLOUD_CONFIG_SWAP_ORDER         : ${SWAP_ORDER}"

if [[ "${UNMANAGED_FORMAT}" != "INI" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: expected openshift-config/cloud-provider-config to be the legacy INI (found ${UNMANAGED_FORMAT}); the legacy cloud-provider-config simulation did not take effect"
  VALIDATION_FAILED=1
fi

# Gate off (pre-bootstrap) => managed mirrors the unmanaged ConfigMap exactly.
# Gate on (post-bootstrap) => managed is CCMO-normalized YAML.
if [[ "${SWAP_ORDER}" == "pre-bootstrap" && "${MANAGED_FORMAT}" == "YAML" ]]; then
  echo "$(date -u --rfc-3339=seconds) - WARNING: swap order is pre-bootstrap (expects VSphereMultiVCenterDay2 OFF, so a verbatim INI copy) but managed/kube-cloud-config is YAML; the gate ownership may have flipped on this payload"
elif [[ "${SWAP_ORDER}" != "pre-bootstrap" && "${MANAGED_FORMAT}" == "INI" ]]; then
  echo "$(date -u --rfc-3339=seconds) - WARNING: swap order is ${SWAP_ORDER} (expects VSphereMultiVCenterDay2 ON, so a CCMO-normalized YAML copy) but managed/kube-cloud-config is INI; the gate ownership may have flipped on this payload"
fi

if [[ "${CONTROLLER_FORMAT}" != "${MANAGED_FORMAT}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - WARNING: ControllerConfig.spec.cloudProviderConfig is ${CONTROLLER_FORMAT} but managed/kube-cloud-config is ${MANAGED_FORMAT}; MCO may not have picked up the managed copy yet"
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
