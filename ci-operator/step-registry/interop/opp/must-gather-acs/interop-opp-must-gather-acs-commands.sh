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

    # Verify ACS is installed
    ACS_CSV=$(oc get csv -n "${ACS_NAMESPACE}" \
      -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" \
      -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "${ACS_CSV}" ]]; then
        echo "WARNING: No ACS CSV found in namespace ${ACS_NAMESPACE} — skipping diagnostic collection."
        echo "SKIPPED: No ACS CSV found" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        return 0
    fi

    # Get Central route
    CENTRAL_HOST=$(oc get route central -n "${ACS_NAMESPACE}" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)

    if [[ -z "${CENTRAL_HOST}" ]]; then
        echo "WARNING: Central route not found in ${ACS_NAMESPACE} — skipping."
        echo "SKIPPED: No Central route" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        return 0
    fi

    # Retrieve admin password
    ADMIN_PW=$(oc get secret central-htpasswd -n "${ACS_NAMESPACE}" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

    if [[ -z "${ADMIN_PW}" ]]; then
        echo "WARNING: Cannot retrieve Central admin password — skipping."
        echo "SKIPPED: No admin credentials" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        return 0
    fi

    # Download diagnostic bundle via Central API
    # (same endpoint roxctl central debug download-diagnostics uses)
    echo "Downloading ACS diagnostic bundle..."

    # Use cluster CA for TLS verification
    CURL_CA_OPTS=""
    if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
        CURL_CA_OPTS="--cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    fi

    # Pass credentials via temp file to keep them out of /proc/cmdline
    CURL_CFG=$(mktemp)
    chmod 600 "${CURL_CFG}"
    trap 'rm -f "${CURL_CFG}"' EXIT
    printf 'user = "admin:%s"\n' "${ADMIN_PW}" > "${CURL_CFG}"

    # shellcheck disable=SC2086
    HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 120 ${CURL_CA_OPTS} -K "${CURL_CFG}" -w '%{http_code}' \
      "https://${CENTRAL_HOST}/v1/debug/diagnostics" \
      -o "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" 2>&1) || {
        echo "WARNING: curl failed to connect to Central."
        echo "FAILED: curl transport error" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
        HTTP_CODE="000"
    }

    if [[ "${HTTP_CODE}" == "200" ]] && \
       [[ -s "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" ]]; then
        echo "ACS diagnostic bundle downloaded (HTTP ${HTTP_CODE})."
        cd "${ARTIFACT_DIR}/acs-must-gather"
        unzip -qo acs-diagnostic-bundle.zip -d diagnostic-bundle 2>/dev/null || true
    else
        echo "WARNING: Diagnostic download failed (HTTP ${HTTP_CODE})."
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
#
# Capture contract (docs/design/acs-deploy-evidence.md in the
# opp-interop-testing workspace is the durable authority):
#   * Every query is classified three ways: present | absent |
#     probe_error:<rc> — a query failure is never rendered as absence.
#   * Both 08-* packagemanifest files are always written, regardless of
#     branch.
#   * Fully-qualified resource types are used wherever ACM CRDs collide
#     with OLM kinds (subscription vs subscriptions.apps.open-cluster-
#     management.io).
#   * Cross-artifact agreement assertions run at the end and fail the
#     step with a named exit code (see ASSERTION EXIT CODES below).
#
# ASSERTION EXIT CODES (this step is best_effort, so the exit code is
# surfaced in the step's finished.json and the properties file carries
# the detail; Prow job color is NOT the signal):
#   20 — cross-artifact agreement assertion failed (captures disagree)
#   21 — evidence probe sanity assertion failed (a required artifact is
#        missing or unparseable)
#   22 — removal-predicate fixture self-test failed (self-test mode only)

set +e

EVIDENCE_DIR="${ARTIFACT_DIR}/olm-evidence"
mkdir -p "${EVIDENCE_DIR}"

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=== OLM Evidence Capture ===" > "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Timestamp: ${TIMESTAMP}" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "OCP Version: $(oc version -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("openshiftVersion","unknown"))' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Cluster ID: $(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"

echo "[${TIMESTAMP}] Starting OLM evidence capture..."

# 1. OperatorPolicy — capture name, spec (subscription target + channel),
#    and status.conditions. The spec is required by the removal predicate
#    (adopt-vs-duplicate and channel comparison); conditions alone cannot
#    distinguish "CRD absent" from "zero objects", so the CRD is probed
#    first and an explicit CRD_ABSENT marker is written when missing.
echo "[1/10] OperatorPolicy..."
if oc get crd operatorpolicies.operator.management.openshift.io >/dev/null 2>&1; then
  oc get operatorpolicy -A -o json 2>/dev/null | \
    python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    spec = i.get("spec", {})
    sub = spec.get("subscription", {})
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "spec": {
            "subscriptionName": sub.get("name"),
            "subscriptionNamespace": sub.get("namespace"),
            "channel": sub.get("channel"),
            "remediationAction": spec.get("remediationAction"),
            "complianceType": spec.get("complianceType"),
        },
        "conditions": i.get("status", {}).get("conditions")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/01-operatorpolicy.json" 2>&1 || \
    echo "probe_error: operatorpolicy query failed" > "${EVIDENCE_DIR}/01-operatorpolicy.json"
else
  echo "CRD_ABSENT: operatorpolicies.operator.management.openshift.io not registered on this cluster" > "${EVIDENCE_DIR}/01-operatorpolicy.json"
fi

# 2. CatalogSource — capture name, status.connectionState, spec.image
echo "[2/10] CatalogSource..."
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
' > "${EVIDENCE_DIR}/02-catalogsource.json" 2>&1 || \
  echo "probe_error: catalogsource query failed" > "${EVIDENCE_DIR}/02-catalogsource.json"

# 3. Subscription — capture name, spec, status.currentCSV/state, and
#    status.conditions (the classification table keys on conditions).
#    Fully-qualified resource type: with ACM installed, the bare
#    `subscription` resolves to ACM's subscriptions.apps.open-cluster-
#    management.io CRD and silently captures the wrong objects.
echo "[3/10] Subscription (OLM, fully-qualified)..."
oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "apiVersion": i.get("apiVersion"),
        "currentCSV": i.get("status", {}).get("currentCSV"),
        "state": i.get("status", {}).get("state"),
        "installPlanRef": (i.get("status", {}).get("installPlanRef") or {}).get("name"),
        "conditions": i.get("status", {}).get("conditions"),
        "channel": i.get("spec", {}).get("channel"),
        "source": i.get("spec", {}).get("source")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/03-subscription.json" 2>&1 || \
  echo "probe_error: subscription query failed" > "${EVIDENCE_DIR}/03-subscription.json"

# 4. InstallPlan — capture name, status.phase, status.conditions
echo "[4/10] InstallPlan..."
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
' > "${EVIDENCE_DIR}/04-installplan.json" 2>&1 || \
  echo "probe_error: installplan query failed" > "${EVIDENCE_DIR}/04-installplan.json"

# 5. CSV — capture name, status.phase, status.reason, status.message
echo "[5/10] ClusterServiceVersion..."
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
' > "${EVIDENCE_DIR}/05-csv.json" 2>&1 || \
  echo "probe_error: csv query failed" > "${EVIDENCE_DIR}/05-csv.json"

# 6. CRD Established condition for Central
echo "[6/10] Central CRD..."
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
' > "${EVIDENCE_DIR}/06-central-crd.json" 2>&1 || \
    echo "probe_error: central crd parse failed" > "${EVIDENCE_DIR}/06-central-crd.json"
else
  if echo "${CRD_OUTPUT}" | grep -qi "not found"; then
    echo "CRD centrals.platform.stackrox.io NOT FOUND" > "${EVIDENCE_DIR}/06-central-crd.json"
  else
    echo "QUERY FAILED (rc=${CRD_RC}): ${CRD_OUTPUT}" > "${EVIDENCE_DIR}/06-central-crd.json"
  fi
fi

# 7. Central CR — capture name, namespace, spec.name, full status, and the
#    Available condition explicitly (the acceptance verdict keys on it).
echo "[7/10] Central CR..."
CR_OUTPUT=$(oc get centrals.platform.stackrox.io -A -o json 2>&1)
CR_RC=$?
if [[ ${CR_RC} -eq 0 ]]; then
  echo "${CR_OUTPUT}" | \
    python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    conds = i.get("status", {}).get("conditions", [])
    available = next((c for c in conds if c.get("type") == "Available"), None)
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "specName": i.get("spec", {}).get("name"),
        "status": i.get("status"),
        "available": available,
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/07-central-cr.json" 2>&1 || \
    echo "probe_error: central cr parse failed" > "${EVIDENCE_DIR}/07-central-cr.json"
else
  if echo "${CR_OUTPUT}" | grep -qi "not found"; then
    echo "No Central CR found (CRD may not exist)" > "${EVIDENCE_DIR}/07-central-cr.json"
  else
    echo "QUERY FAILED (rc=${CR_RC}): ${CR_OUTPUT}" > "${EVIDENCE_DIR}/07-central-cr.json"
  fi
fi

# 7b. SecuredCluster CR — same three-way classification as Central; the
#     SecuredCluster gap is tracked separately (see INTEROP-9525 child) and
#     its presence/phase must be observable from the evidence bundle.
echo "[7b/10] SecuredCluster CR..."
SC_OUTPUT=$(oc get securedclusters.platform.stackrox.io -A -o json 2>&1)
SC_RC=$?
if [[ ${SC_RC} -eq 0 ]]; then
  echo "${SC_OUTPUT}" | \
    python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    conds = i.get("status", {}).get("conditions", [])
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "status": i.get("status"),
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/07b-securedcluster-cr.json" 2>&1 || \
    echo "probe_error: securedcluster parse failed" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
else
  if echo "${SC_OUTPUT}" | grep -qi "not found"; then
    echo "No SecuredCluster CR found (CRD may not exist)" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
  else
    echo "QUERY FAILED (rc=${SC_RC}): ${SC_OUTPUT}" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
  fi
fi

# 8. PackageManifest for rhacs-operator — three-way classify (present |
#    absent | probe_error); both files are ALWAYS written. The previous
#    --selector=catalog=redhat-operators form false-negatived on clusters
#    where the operator installs fine, and the "not in catalog" conclusion
#    was read from that broken probe.
echo "[8/10] PackageManifest..."
PM_OUTPUT=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>&1)
PM_RC=$?
if [[ ${PM_RC} -eq 0 ]]; then
  echo "${PM_OUTPUT}" | \
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
' > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json" 2>&1 || \
    echo "probe_error: packagemanifest parse failed" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
else
  if echo "${PM_OUTPUT}" | grep -qi "not found"; then
    echo "ABSENT: no PackageManifest named rhacs-operator in openshift-marketplace (successful query)" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
  else
    echo "QUERY FAILED (rc=${PM_RC}): ${PM_OUTPUT}" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
  fi
fi
# Always written, not only on the failure branch.
oc get packagemanifest -n openshift-marketplace -o name > "${EVIDENCE_DIR}/08-all-packagemanifests.txt" 2>&1 || \
  echo "probe_error: packagemanifest list query failed" > "${EVIDENCE_DIR}/08-all-packagemanifests.txt"

# 9/10. ACM policies — capture name, status.conditions, and the compliance
#      verdicts (status.compliant, status.status[]). Conditions alone are
#      always null on these objects; the compliance verdict is the field
#      that answers "was the policy reconciled".
echo "[9/10] ACM policies..."
oc get policy -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "conditions": i.get("status", {}).get("conditions"),
        "compliant": i.get("status", {}).get("compliant"),
        "status": i.get("status", {}).get("status"),
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/09-policies.json" 2>&1 || \
  echo "probe_error: policy query failed" > "${EVIDENCE_DIR}/09-policies.json"
oc get configurationpolicy -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "conditions": i.get("status", {}).get("conditions"),
        "compliant": i.get("status", {}).get("compliant"),
        "status": i.get("status", {}).get("status"),
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/10-configpolicies.json" 2>&1 || \
  echo "probe_error: configurationpolicy query failed" > "${EVIDENCE_DIR}/10-configpolicies.json"

# 10. ACM CSV version and governance-policy-addon-controller image ref —
#     the removal predicate keys on the ACM build carrying
#     stolostron/governance-policy-addon-controller#1397.
echo "[10/10] ACM CSV + addon-controller image..."
oc get csv -A -o json 2>/dev/null | \
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    name = i["metadata"]["name"]
    if not name.startswith("advanced-cluster-management"):
        continue
    images = []
    for img in i.get("spec", {}).get("relatedImages", []) or []:
        if "governance-policy-addon-controller" in (img.get("name") or "") + (img.get("image") or ""):
            images.append(img)
    result.append({
        "name": name,
        "namespace": i["metadata"].get("namespace", ""),
        "phase": i.get("status", {}).get("phase"),
        "version": i.get("spec", {}).get("version"),
        "governancePolicyAddonControllerImages": images,
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/11-acm-csv-addon-controller.json" 2>&1 || \
  echo "probe_error: acm csv query failed" > "${EVIDENCE_DIR}/11-acm-csv-addon-controller.json"

# ─── Removal predicate (per-run terms) ──────────────────────────────────────
# Evaluates the per-run facts defined in
# docs/design/acs-deploy-evidence.md §3 and writes them to
# acs-central-status.properties next to the evidence. The two-run
# aggregation is a ticket-level rule, NOT computed here.
write_status_properties() {
  python3 - "$EVIDENCE_DIR" <<'PYEOF'
import json, sys
from pathlib import Path

ev = Path(sys.argv[1])

def load(name):
    try:
        return json.loads((ev / name).read_text())
    except Exception:
        return None

ops = load("01-operatorpolicy.json") or []
subs = load("03-subscription.json") or []
csvs = load("05-csv.json") or []
central = load("07-central-cr.json") or []
acm = load("11-acm-csv-addon-controller.json") or []

rhacs_subs = [s for s in subs if s.get("name") == "rhacs-operator"]
rhacs_csvs = [c for c in csvs if c.get("name", "").startswith("rhacs-operator.v")]
rhacs_op = [o for o in ops if o.get("name") == "operatorpolicy-rhacs-operator"]

sub_channel = rhacs_subs[0].get("channel") if len(rhacs_subs) == 1 else None
op_spec = (rhacs_op[0].get("spec") or {}) if rhacs_op else {}
op_channel = op_spec.get("channel")
op_compliant = None
if rhacs_op:
    conds = rhacs_op[0].get("conditions") or []
    op_compliant = any(
        c.get("type") == "Compliant" and c.get("status") == "True"
        for c in conds
    )

central_present = bool(central) and isinstance(central, list) and len(central) > 0
central_available = any(
    (c.get("available") or {}).get("status") == "True" for c in central
) if central_present else False

acm_version = None
addon_images = []
for a in acm:
    if a.get("version"):
        acm_version = a["version"]
    addon_images += a.get("governancePolicyAddonControllerImages") or []

terms = {
    "central_present": str(central_present).lower(),
    "central_available": str(central_available).lower(),
    "rhacs_subscription_count": str(len(rhacs_subs)),
    "rhacs_subscription_channel": sub_channel or "unknown",
    "rhacs_csv_count": str(len(rhacs_csvs)),
    "rhacs_csv_name": rhacs_csvs[0]["name"] if rhacs_csvs else "unknown",
    "operatorpolicy_present": str(bool(rhacs_op)).lower(),
    "operatorpolicy_compliant": (str(op_compliant).lower()
                                  if op_compliant is not None else "unknown"),
    "operatorpolicy_spec_channel": op_channel or "unknown",
    "acm_csv_version": acm_version or "unknown",
    "addon_controller_image": (addon_images[0].get("image")
                                if addon_images else "unknown"),
}
# Per-run removal precondition: the OperatorPolicy owns the rhacs
# subscription with a matching channel and a Succeeded CSV. The two-run
# aggregation and the named-build comparison live in the ticket rule.
terms["removal_preconditions_met"] = str(
    terms["operatorpolicy_compliant"] == "true"
    and terms["rhacs_subscription_count"] == "1"
    and terms["rhacs_csv_count"] == "1"
    and terms["rhacs_subscription_channel"] != "unknown"
    and terms["rhacs_subscription_channel"] == terms["operatorpolicy_spec_channel"]
).lower()

out = ev / "acs-central-status.properties"
with out.open("w") as f:
    f.write("# ACS central/removal-predicate status (per-run terms)\n")
    for k in sorted(terms):
        f.write(f"{k}={terms[k]}\n")
print(f"wrote {out}")
PYEOF
}

write_status_properties

# ─── Cross-artifact agreement assertions ────────────────────────────────────
# A query failure must never read as absence, and captures that describe the
# same cluster state must agree. These assertions fail the step (exit 20/21)
# so the disagreement is visible in finished.json — job color is not the
# signal (this step is best_effort).
run_assertions() {
  local failed=0
  # (a) No evidence file may carry a probe_error marker.
  for f in "${EVIDENCE_DIR}"/*.json "${EVIDENCE_DIR}"/*.txt; do
    if grep -q "^probe_error:" "${f}" 2>/dev/null; then
      echo "ASSERTION FAILURE (21): ${f} carries a probe_error marker — evidence incomplete"
      failed=21
    fi
  done
  # (b) Packagemanifest agreement: if the full list names rhacs-operator,
  #     the per-package capture must classify it present (valid JSON with a
  #     name field), and vice versa.
  python3 - "${EVIDENCE_DIR}" <<'PYEOF' || failed=20
import json, sys
from pathlib import Path
ev = Path(sys.argv[1])
listed = "rhacs-operator" in (ev / "08-all-packagemanifests.txt").read_text()
perpkg_raw = (ev / "08-packagemanifest-rhacs.json").read_text()
if perpkg_raw.startswith("ABSENT:"):
    present = False
else:
    try:
        perpkg = json.loads(perpkg_raw)
        present = isinstance(perpkg, dict) and perpkg.get("name") == "rhacs-operator"
    except Exception:
        present = None
if present is None:
    print("ASSERTION FAILURE (21): 08-packagemanifest-rhacs.json is not valid JSON")
    sys.exit(21)
if listed != present:
    print(f"ASSERTION FAILURE (20): packagemanifest disagreement — "
          f"full list contains rhacs-operator={listed}, per-package present={present}")
    sys.exit(20)
PYEOF
  # (c) Subscription capture must be OLM objects, not ACM's CRD.
  python3 - "${EVIDENCE_DIR}" <<'PYEOF' || failed=21
import json, sys
from pathlib import Path
ev = Path(sys.argv[1])
subs = json.loads((ev / "03-subscription.json").read_text())
if not isinstance(subs, list):
    sys.exit(21)
for s in subs:
    if s.get("apiVersion") and not s["apiVersion"].startswith("operators.coreos.com"):
        print(f"ASSERTION FAILURE (21): non-OLM subscription captured: {s.get('apiVersion')}")
        sys.exit(21)
PYEOF
  return "${failed}"
}

# ─── Removal-predicate fixture self-test ────────────────────────────────────
# Positive control for the removal predicate: evaluates the same term
# computation against embedded TRUE and FALSE fixtures. Run by setting
# ACS_EVIDENCE_SELF_TEST=1 (used in the PR rehearsal; exit 22 on failure).
self_test() {
  local tmp
  tmp=$(mktemp -d)
  # TRUE fixture: OperatorPolicy compliant, one subscription+CSV, matching
  # channel. FALSE fixture: no OperatorPolicy (today's 5.0 state).
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies",
  "spec": {"subscriptionName": "rhacs-operator",
           "subscriptionNamespace": "rhacs-operator",
           "channel": "stable", "remediationAction": "enforce",
           "complianceType": "musthave"},
  "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  cat > "${tmp}/03-subscription.json" <<'FIXTURE'
[{"name": "rhacs-operator", "namespace": "rhacs-operator",
  "apiVersion": "operators.coreos.com/v1alpha1",
  "currentCSV": "rhacs-operator.v4.11.6", "state": "AtLatestKnown",
  "conditions": [], "channel": "stable", "source": "redhat-operators"}]
FIXTURE
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Succeeded"}]' > "${tmp}/05-csv.json"
  echo '[{"name": "central", "namespace": "stackrox", "available": {"type": "Available", "status": "True"}}]' > "${tmp}/07-central-cr.json"
  echo '[{"name": "advanced-cluster-management.v2.17.4", "version": "2.17.4", "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]}]' > "${tmp}/11-acm-csv-addon-controller.json"

  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  local true_val
  true_val=$(grep '^removal_preconditions_met=' "${tmp}/acs-central-status.properties" | cut -d= -f2)
  if [[ "${true_val}" != "true" ]]; then
    echo "SELF-TEST FAILURE (22): TRUE fixture evaluated removal_preconditions_met=${true_val}"
    rm -rf "${tmp}"
    return 22
  fi

  # FALSE fixture: empty OperatorPolicy (current gated state).
  echo '[]' > "${tmp}/01-operatorpolicy.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  local false_val
  false_val=$(grep '^removal_preconditions_met=' "${tmp}/acs-central-status.properties" | cut -d= -f2)
  if [[ "${false_val}" != "false" ]]; then
    echo "SELF-TEST FAILURE (22): FALSE fixture evaluated removal_preconditions_met=${false_val}"
    rm -rf "${tmp}"
    return 22
  fi
  echo "SELF-TEST PASS: TRUE fixture -> true; FALSE fixture -> false"
  rm -rf "${tmp}"
  return 0
}

if [[ "${ACS_EVIDENCE_SELF_TEST:-0}" == "1" ]]; then
  self_test
  exit $?
fi

# Summary
echo ""
echo "=== OLM evidence capture complete: $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
echo "Output directory: ${EVIDENCE_DIR}"
echo ""
echo "Quick check:"
ls -la "${EVIDENCE_DIR}/"
echo ""
# Verdict counters use the fully-qualified OLM type: with ACM installed,
# bare `oc get subscription` resolves to ACM's CRD and counts nothing.
SUBSCRIPTION_COUNT=$(oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null | grep -ci "rhacs" 2>/dev/null || true)
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

CR_CHECK=$(oc get centrals.platform.stackrox.io -A --no-headers 2>&1)
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
echo "VERDICT: RHACS subscriptions=${SUBSCRIPTION_COUNT} CRD=${CRD_EXISTS} Central=${CENTRAL_EXISTS}"
cat "${EVIDENCE_DIR}/acs-central-status.properties" || true

# Assertions run last so every capture is already on disk; a failure here
# fails the step (best_effort keeps the job green; finished.json carries it).
run_assertions
ASSERT_RC=$?
if [[ ${ASSERT_RC} -ne 0 ]]; then
  echo "EVIDENCE ASSERTIONS FAILED (rc=${ASSERT_RC}) — see messages above"
  exit ${ASSERT_RC}
fi
echo "EVIDENCE ASSERTIONS PASSED"
