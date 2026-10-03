#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# ─── ACS Diagnostic Collection ──────────────────────────────────────────────
# Wrapped in a function so early returns (when ACS is not available) do not
# prevent the OLM evidence capture section from running.  This is critical
# because OLM evidence is most valuable when the operator fails to install.

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
    HTTP_CODE=$(curl -s ${CURL_CA_OPTS} -K "${CURL_CFG}" -w '%{http_code}' \
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
}

collect_acs_diagnostics || true

# ─── OLM Evidence Capture (INTEROP-9525) ────────────────────────────────────
# Captures OLM lifecycle state to diagnose why Central CR creation fails
# on OCP 5.0/5.1. Runs with set +e so every command executes even when
# preceding ones fail — capturing absence IS evidence.

set +e

EVIDENCE_DIR="${ARTIFACT_DIR}/olm-evidence"
mkdir -p "${EVIDENCE_DIR}"

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=== OLM Evidence Capture ===" > "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Timestamp: ${TIMESTAMP}" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "OCP Version: $(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // "unknown"')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Cluster ID: $(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"

echo "[${TIMESTAMP}] Starting OLM evidence capture..."

# 1. OperatorPolicy status
echo "[1/8] OperatorPolicy..."
oc get operatorpolicy -A -o yaml > "${EVIDENCE_DIR}/01-operatorpolicy.yaml" 2>&1
oc get operatorpolicy -A -o json 2>/dev/null | \
  jq '.items[] | select(.metadata.name | test("rhacs|acs"; "i")) | {name: .metadata.name, namespace: .metadata.namespace, status: .status}' \
  > "${EVIDENCE_DIR}/01-operatorpolicy-rhacs-summary.json" 2>&1 || true

# 2. CatalogSource resolution
echo "[2/8] CatalogSource..."
oc get catalogsource -n openshift-marketplace -o yaml > "${EVIDENCE_DIR}/02-catalogsource.yaml" 2>&1
oc get catalogsource -n openshift-marketplace -o json 2>/dev/null | \
  jq '.items[] | {name: .metadata.name, image: .spec.image, ready: .status.connectionState.lastObservedState}' \
  > "${EVIDENCE_DIR}/02-catalogsource-summary.json" 2>&1 || true

# 3. Subscription status and currentCSV
echo "[3/8] Subscription..."
oc get subscription -A -o yaml > "${EVIDENCE_DIR}/03-subscription-all.yaml" 2>&1
for NS in ocm rhacs-operator stackrox openshift-operators; do
  oc get subscription -n "${NS}" -o yaml > "${EVIDENCE_DIR}/03-subscription-${NS}.yaml" 2>&1 || true
done

# 4. InstallPlan phase and conditions
echo "[4/8] InstallPlan..."
oc get installplan -A -o yaml > "${EVIDENCE_DIR}/04-installplan-all.yaml" 2>&1
oc get installplan -A -o json 2>/dev/null | \
  jq '.items[] | {namespace: .metadata.namespace, name: .metadata.name, phase: .status.phase, csvNames: .spec.clusterServiceVersionNames}' \
  > "${EVIDENCE_DIR}/04-installplan-summary.json" 2>&1 || true

# 5. CSV phase and reason
echo "[5/8] ClusterServiceVersion..."
oc get csv -A -o yaml > "${EVIDENCE_DIR}/05-csv-all.yaml" 2>&1
oc get csv -A -o json 2>/dev/null | \
  jq '.items[] | {namespace: .metadata.namespace, name: .metadata.name, phase: .status.phase, reason: .status.reason}' \
  > "${EVIDENCE_DIR}/05-csv-summary.json" 2>&1 || true

# 6. CRD Established condition for Central
echo "[6/8] Central CRD..."
if oc get crd centrals.platform.stackrox.io -o yaml > "${EVIDENCE_DIR}/06-central-crd.yaml" 2>&1; then
  oc get crd centrals.platform.stackrox.io -o json | \
    jq '.status.conditions[] | select(.type == "Established")' \
    > "${EVIDENCE_DIR}/06-central-crd-established.json" 2>&1 || true
else
  echo "CRD centrals.platform.stackrox.io NOT FOUND" > "${EVIDENCE_DIR}/06-central-crd.yaml"
fi

# 7. Central CR result
echo "[7/8] Central CR..."
if oc get central -A -o yaml > "${EVIDENCE_DIR}/07-central-cr.yaml" 2>&1; then
  oc get central -A -o json | \
    jq '.items[] | {namespace: .metadata.namespace, name: .metadata.name, conditions: .status.conditions}' \
    > "${EVIDENCE_DIR}/07-central-cr-summary.json" 2>&1 || true
else
  echo "No Central CR found (CRD may not exist)" > "${EVIDENCE_DIR}/07-central-cr.yaml"
fi

# 8. PackageManifest for rhacs-operator
echo "[8/8] PackageManifest..."
if ! oc get packagemanifest rhacs-operator -o yaml > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.yaml" 2>&1; then
  echo "No PackageManifest for rhacs-operator — operator may not be in catalog" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.yaml"
  oc get packagemanifest -o name > "${EVIDENCE_DIR}/08-all-packagemanifests.txt" 2>&1 || true
fi

# Bonus: ACM policy context
echo "[Bonus] ACM policies..."
oc get policy -A -o yaml > "${EVIDENCE_DIR}/09-policies.yaml" 2>&1 || true
oc get configurationpolicy -A -o yaml > "${EVIDENCE_DIR}/10-configpolicies.yaml" 2>&1 || true

# Summary
echo ""
echo "=== OLM evidence capture complete: $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
echo "Output directory: ${EVIDENCE_DIR}"
echo ""
echo "Quick check:"
ls -la "${EVIDENCE_DIR}/"
echo ""
SUBSCRIPTION_COUNT=$(oc get subscription -A --no-headers 2>/dev/null | grep -ci "rhacs\|acs" || echo "0")
CRD_EXISTS=$(oc get crd centrals.platform.stackrox.io --no-headers 2>/dev/null && echo "YES" || echo "NO")
CENTRAL_EXISTS=$(oc get central -A --no-headers 2>/dev/null && echo "YES" || echo "NO")
echo "VERDICT: RHACS subscriptions=${SUBSCRIPTION_COUNT} CRD=${CRD_EXISTS} Central=${CENTRAL_EXISTS}"
