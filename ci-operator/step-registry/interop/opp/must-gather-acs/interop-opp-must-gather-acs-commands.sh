#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# ─── ACS Diagnostic Collection ──────────────────────────────────────────────
# Wrapped in a function so early returns (when ACS is not available) do not
# prevent the OLM evidence capture section from running.  This is critical
# because OLM evidence is most valuable when the operator fails to install.

# collect_acs_diagnostics — downloads ACS/StackRox diagnostic bundle
# via the Central API. Skips silently if ACS is not installed.
collect_acs_diagnostics() {
    mkdir -p "${ARTIFACT_DIR}/acs-must-gather"
    BUNDLE_STATUS="not-attempted"

    # Verify ACS is installed (operator namespace)
    ACS_CSV=$(oc get csv -n "${ACS_NAMESPACE}" \
      -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" \
      -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "${ACS_CSV}" ]]; then
        echo "WARNING: No ACS CSV found in namespace ${ACS_NAMESPACE} — skipping diagnostic collection."
        echo "SKIPPED: No ACS CSV found" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-csv"
        return 0
    fi

    # The Central workload (route, secret, diagnostic bundle) runs in the
    # namespace named by the Central CR — NOT the operator namespace
    # (ACS_NAMESPACE). Discover it from the CR; without a CR there is no
    # Central to gather from. (INTEROP-9647 D9: this step was previously
    # dead on every stanza — route/secret were queried in the operator
    # namespace and always came back empty.)
    WORKLOAD_NS=$(oc get central -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    if [[ -z "${WORKLOAD_NS}" ]]; then
        echo "WARNING: No Central CR found — cannot determine the ACS workload namespace."
        echo "SKIPPED: No Central CR" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-central-cr"
        return 0
    fi
    echo "ACS workload namespace (from Central CR): ${WORKLOAD_NS}; operator namespace: ${ACS_NAMESPACE}"

    # Get Central route (workload namespace)
    CENTRAL_HOST=$(oc get route central -n "${WORKLOAD_NS}" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)

    if [[ -z "${CENTRAL_HOST}" ]]; then
        echo "WARNING: Central route not found in ${WORKLOAD_NS} — skipping."
        echo "SKIPPED: No Central route" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-route"
        return 0
    fi

    # Retrieve admin password (workload namespace)
    ADMIN_PW=$(oc get secret central-htpasswd -n "${WORKLOAD_NS}" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

    if [[ -z "${ADMIN_PW}" ]]; then
        echo "WARNING: Cannot retrieve Central admin password — skipping."
        echo "SKIPPED: No admin credentials" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-credentials"
        return 0
    fi

    # Download diagnostic bundle via Central API
    # (same endpoint roxctl central debug download-diagnostics uses)
    echo "Downloading ACS diagnostic bundle..."

    # TLS posture: the route certificate is signed by the ingress operator's
    # CA, not the API-server CA exposed at the serviceaccount mount, so
    # --cacert against the serviceaccount ca.crt fails verification (HTTP
    # 000, observed in rehearsal build 2116737836412571648). Match the
    # readiness step's precedent: curl -sk (insecure), with the mode
    # disclosed here - this step collects evidence, it does not verify TLS.
    CURL_TLS_OPTS="-k"

    # Pass credentials via temp file to keep them out of /proc/cmdline
    CURL_CFG=$(mktemp)
    chmod 600 "${CURL_CFG}"
    trap 'rm -f "${CURL_CFG}"' EXIT
    printf 'user = "admin:%s"\n' "${ADMIN_PW}" > "${CURL_CFG}"

    # shellcheck disable=SC2086
    HTTP_CODE=$(curl -s ${CURL_TLS_OPTS} --connect-timeout 10 --max-time 120 -K "${CURL_CFG}" -w '%{http_code}' \
      "https://${CENTRAL_HOST}/v1/debug/diagnostics" \
      -o "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" 2>&1) || {
        echo "WARNING: curl failed to connect to Central."
        echo "FAILED: curl transport error" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
        BUNDLE_STATUS="failed:transport"
        HTTP_CODE="000"
    }

    if [[ "${HTTP_CODE}" == "200" ]] && \
       [[ -s "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" ]]; then
        echo "ACS diagnostic bundle downloaded (HTTP ${HTTP_CODE})."
        BUNDLE_STATUS="downloaded"
        cd "${ARTIFACT_DIR}/acs-must-gather"
        unzip -qo acs-diagnostic-bundle.zip -d diagnostic-bundle 2>/dev/null || true
    else
        echo "WARNING: Diagnostic download failed (HTTP ${HTTP_CODE})."
        BUNDLE_STATUS="failed:http-${HTTP_CODE}"
        if [[ "${HTTP_CODE}" != "000" ]]; then
            echo "FAILED: HTTP ${HTTP_CODE}" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
        fi
    fi

    # Clean up credentials file immediately — the EXIT trap only fires at
    # script end, so remove it here to avoid the password persisting through
    # the OLM evidence capture section.
    rm -f "${CURL_CFG}"
}

collect_acs_diagnostics || true

# ─── OLM Evidence Capture (INTEROP-9525) ────────────────────────────────────
# Captures OLM lifecycle state to diagnose why Central CR creation fails
# on OCP 5.0/5.1. Runs with set +e so every command executes even when
# preceding ones fail — capturing absence IS evidence.
#
# Each resource is captured with targeted field extraction (not full -o yaml
# or -o json dumps) to avoid leaking sensitive fields such as registry
# credentials, tokens, passwords, or secret refs in operator specs.

set +e

EVIDENCE_DIR="${ARTIFACT_DIR}/olm-evidence"
mkdir -p "${EVIDENCE_DIR}"

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=== OLM Evidence Capture ===" > "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Timestamp: ${TIMESTAMP}" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "OCP Version: $(oc version -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("openshiftVersion","unknown"))' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Cluster ID: $(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"

echo "[${TIMESTAMP}] Starting OLM evidence capture..."

# 1. OperatorPolicy — capture name + status.conditions only
echo "[1/8] OperatorPolicy..."
oc get operatorpolicy -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "conditions": i.get("status", {}).get("conditions")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/01-operatorpolicy.json" 2>&1 || true

# 2. CatalogSource — capture name, status.connectionState, spec.image
echo "[2/8] CatalogSource..."
oc get catalogsource -n openshift-marketplace -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "image": i.get("spec", {}).get("image"),
        "connectionState": i.get("status", {}).get("connectionState")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/02-catalogsource.json" 2>&1 || true

# 3. Subscription — capture name, status.currentCSV, status.state, spec.channel, spec.source
echo "[3/8] Subscription..."
oc get subscription -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "currentCSV": i.get("status", {}).get("currentCSV"),
        "state": i.get("status", {}).get("state"),
        "channel": i.get("spec", {}).get("channel"),
        "source": i.get("spec", {}).get("source")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/03-subscription.json" 2>&1 || true

# 4. InstallPlan — capture name, status.phase, status.conditions
echo "[4/8] InstallPlan..."
oc get installplan -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "phase": i.get("status", {}).get("phase"),
        "conditions": i.get("status", {}).get("conditions")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/04-installplan.json" 2>&1 || true

# 5. CSV — capture name, status.phase, status.reason, status.message
echo "[5/8] ClusterServiceVersion..."
oc get csv -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "phase": i.get("status", {}).get("phase"),
        "reason": i.get("status", {}).get("reason"),
        "message": i.get("status", {}).get("message")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/05-csv.json" 2>&1 || true

# 6. CRD Established condition for Central
echo "[6/8] Central CRD..."
CRD_OUTPUT=$(oc get crd centrals.platform.stackrox.io -o json 2>&1)
CRD_RC=$?
if [[ ${CRD_RC} -eq 0 ]]; then
  echo "${CRD_OUTPUT}" | \
    python3 -c '
import json, sys
data = json.load(sys.stdin)
conditions = data.get("status", {}).get("conditions", [])
print(json.dumps({
    "name": data["metadata"]["name"],
    "conditions": conditions
}, indent=2))
' > "${EVIDENCE_DIR}/06-central-crd.json" 2>&1 || true
else
  if echo "${CRD_OUTPUT}" | grep -qi "not found"; then
    echo "CRD centrals.platform.stackrox.io NOT FOUND" > "${EVIDENCE_DIR}/06-central-crd.json"
  else
    echo "QUERY FAILED (rc=${CRD_RC}): ${CRD_OUTPUT}" > "${EVIDENCE_DIR}/06-central-crd.json"
  fi
fi

# 7. Central CR — capture name + full status (status is the key diagnostic info)
echo "[7/8] Central CR..."
CR_OUTPUT=$(oc get central -A -o json 2>&1)
CR_RC=$?
if [[ ${CR_RC} -eq 0 ]]; then
  echo "${CR_OUTPUT}" | \
    python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "status": i.get("status")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/07-central-cr.json" 2>&1 || true
else
  if echo "${CR_OUTPUT}" | grep -qi "not found"; then
    echo "No Central CR found (CRD may not exist)" > "${EVIDENCE_DIR}/07-central-cr.json"
  else
    echo "QUERY FAILED (rc=${CR_RC}): ${CR_OUTPUT}" > "${EVIDENCE_DIR}/07-central-cr.json"
  fi
fi

# 8. PackageManifest for rhacs-operator — capture name, status.channels
#    Uses --selector=catalog=redhat-operators to avoid ambiguity on multi-catalog clusters.
echo "[8/8] PackageManifest..."
if ! oc get packagemanifest rhacs-operator -n openshift-marketplace \
     --selector=catalog=redhat-operators -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
channels = []
for ch in data.get("status", {}).get("channels", []):
    channels.append({
        "name": ch.get("name"),
        "currentCSV": ch.get("currentCSV")
    })
print(json.dumps({"name": data["metadata"]["name"], "channels": channels}, indent=2))
' > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json" 2>&1; then
  echo "No PackageManifest for rhacs-operator — operator may not be in catalog" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
  oc get packagemanifest -n openshift-marketplace -o name > "${EVIDENCE_DIR}/08-all-packagemanifests.txt" 2>&1 || true
fi

# Bonus: ACM policy context — targeted compliance fields (INTEROP-9647 Stage 0).
# status.compliant + status.status[] (per-cluster compliance) per policy name;
# conditions alone cannot answer whether ACS policies reached Compliant.
echo "[Bonus] ACM policies (compliance fields)..."
oc get policy -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    status = i.get("status", {})
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "compliant": status.get("compliant"),
        "status": [
            {"clusterName": s.get("clusterName"), "compliant": s.get("compliant")}
            for s in status.get("status", []) or []
        ]
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/09-policies.json" 2>&1 || true
oc get configurationpolicy -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "compliant": i.get("status", {}).get("compliant"),
        "conditions": i.get("status", {}).get("conditions")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/10-configpolicies.json" 2>&1 || true

# 11. PlacementDecisions — cluster names only (INTEROP-9647 Stage 0: which
#     clusters the placements selected; answers whether
#     placement-openshift-plus-hub selected any cluster for policy propagation)
echo "[11] PlacementDecisions..."
oc get placementdecisions -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    decisions = [
        {"clusterName": d.get("clusterName")}
        for d in i.get("status", {}).get("decisions", []) or []
    ]
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "decisions": decisions
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/11-placementdecisions.json" 2>&1 || true

# ─── Storage-axis capture (INTEROP-9647 Stage 0 / 9646 ENOSPC context) ──────
# The documented failure mode on these lanes is node storage exhaustion
# (ENOSPC on small-root workerocs nodes), not CPU/memory pressure. Capture
# the storage axis specifically: PVCs and their StorageClasses, node
# ephemeral-storage capacity/allocatable plus pressure conditions, MCP
# rollout state, stackrox DaemonSet scheduling, and workerocs machinesets.

# 12. PVCs — name, namespace, StorageClass, requested size, phase
echo "[12] PVCs (storage axis)..."
oc get pvc -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "storageClassName": i.get("spec", {}).get("storageClassName"),
        "requestedStorage": i.get("spec", {}).get("resources", {}).get("requests", {}).get("storage"),
        "phase": i.get("status", {}).get("phase")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/12-pvcs.json" 2>&1 || true

# 13. Nodes — role, age, pressure conditions, ephemeral-storage capacity.
#     Per-node "used" is not exposed via the node object; DiskPressure
#     conditions are the pressure signal actually available.
echo "[13] Nodes (storage axis)..."
oc get nodes -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    m = i["metadata"]
    roles = sorted(
        k.split("/")[-1]
        for k in m.get("labels", {})
        if k.startswith("node-role.kubernetes.io/")
    )
    conditions = [
        {"type": c.get("type"), "status": c.get("status"), "reason": c.get("reason")}
        for c in i.get("status", {}).get("conditions", [])
        if c.get("type") in ("DiskPressure", "MemoryPressure", "PIDPressure", "Ready")
    ]
    cap = i.get("status", {}).get("capacity", {})
    alloc = i.get("status", {}).get("allocatable", {})
    result.append({
        "name": m["name"],
        "roles": roles,
        "creationTimestamp": m.get("creationTimestamp"),
        "conditions": conditions,
        "ephemeralStorageCapacity": cap.get("ephemeral-storage"),
        "ephemeralStorageAllocatable": alloc.get("ephemeral-storage")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/13-nodes-storage.json" 2>&1 || true

# 14. MachineConfigPools — rollout state (the 9646 ENOSPC showed worker
#     Degraded with MCD write failures)
echo "[14] MachineConfigPools..."
oc get mcp -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    s = i.get("status", {})
    result.append({
        "name": i["metadata"]["name"],
        "machineCount": s.get("machineCount"),
        "readyMachineCount": s.get("readyMachineCount"),
        "updatedMachineCount": s.get("updatedMachineCount"),
        "degradedMachineCount": s.get("degradedMachineCount"),
        "conditions": [
            {"type": c.get("type"), "status": c.get("status"), "reason": c.get("reason")}
            for c in s.get("conditions", [])
            if c.get("type") in ("Degraded", "Updated", "Updating")
        ]
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/14-machineconfigpools.json" 2>&1 || true

# 15. StackRox DaemonSets — collector/sensor scheduling (desired vs ready)
echo "[15] StackRox DaemonSets..."
export STAGE0_WORKLOAD_NS="${WORKLOAD_NS:-}"
export STAGE0_OPERATOR_NS="${ACS_NAMESPACE}"
oc get daemonset -A -o json 2>/dev/null | \
  python3 -c '
import json, os, sys
data = json.load(sys.stdin)
workload = os.environ.get("STAGE0_WORKLOAD_NS", "")
operator_ns = os.environ.get("STAGE0_OPERATOR_NS", "")
result = []
for i in data.get("items", []):
    name = i["metadata"]["name"]
    ns = i["metadata"].get("namespace", "")
    if ns not in (workload, operator_ns) and name not in ("collector", "sensor"):
        continue
    s = i.get("status", {})
    result.append({
        "name": name,
        "namespace": ns,
        "desiredNumberScheduled": s.get("desiredNumberScheduled"),
        "numberReady": s.get("numberReady")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/15-stackrox-daemonsets.json" 2>&1 || true

# 16. workerocs machinesets — the policy-created nodes with small roots
echo "[16] workerocs machinesets..."
oc get machinesets -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    name = i["metadata"]["name"]
    if "workerocs" not in name:
        continue
    s = i.get("status", {})
    result.append({
        "name": name,
        "namespace": i["metadata"].get("namespace", ""),
        "specReplicas": i.get("spec", {}).get("replicas"),
        "readyReplicas": s.get("readyReplicas"),
        "replicas": s.get("replicas")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/16-workerocs-machinesets.json" 2>&1 || true

# 17. ACS image footprint — container images of ACS deployments (operator
#     and workload namespaces)
echo "[17] ACS image footprint..."
oc get deployments -A -o json 2>/dev/null | \
  python3 -c '
import json, os, sys
data = json.load(sys.stdin)
workload = os.environ.get("STAGE0_WORKLOAD_NS", "")
operator_ns = os.environ.get("STAGE0_OPERATOR_NS", "")
result = []
for i in data.get("items", []):
    name = i["metadata"]["name"]
    ns = i["metadata"].get("namespace", "")
    if ns not in (workload, operator_ns):
        continue
    containers = [
        {"name": c.get("name"), "image": c.get("image")}
        for c in i.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    ]
    result.append({"name": name, "namespace": ns, "containers": containers})
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/17-acs-images.json" 2>&1 || true

# Summary
echo ""
echo "=== OLM evidence capture complete: $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
echo "Output directory: ${EVIDENCE_DIR}"
echo ""
echo "Quick check:"
ls -la "${EVIDENCE_DIR}/"
echo ""
SUBSCRIPTION_COUNT=$(oc get subscription -A --no-headers 2>/dev/null | grep -ci "rhacs\|acs" 2>/dev/null || true)
SUBSCRIPTION_COUNT="${SUBSCRIPTION_COUNT:-0}"

CRD_CHECK=$(oc get crd centrals.platform.stackrox.io --no-headers 2>&1)
CRD_RC=$?
if [[ ${CRD_RC} -eq 0 ]]; then
  CRD_EXISTS="YES"
else
  if echo "${CRD_CHECK}" | grep -qi "not found"; then
    CRD_EXISTS="NO"
  else
    CRD_EXISTS="ERROR"
  fi
fi

CR_CHECK=$(oc get central -A --no-headers 2>&1)
CR_RC=$?
if [[ ${CR_RC} -eq 0 ]] && echo "${CR_CHECK}" | grep -q .; then
  CENTRAL_EXISTS="YES"
else
  if [[ ${CR_RC} -eq 0 ]] || echo "${CR_CHECK}" | grep -qi "not found\|no resources"; then
    CENTRAL_EXISTS="NO"
  else
    CENTRAL_EXISTS="ERROR"
  fi
fi
echo "VERDICT: RHACS subscriptions=${SUBSCRIPTION_COUNT} CRD=${CRD_EXISTS} Central=${CENTRAL_EXISTS} workload-ns=${WORKLOAD_NS:-unknown} bundle=${BUNDLE_STATUS:-not-attempted}"
