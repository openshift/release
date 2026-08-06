#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# ODF Health Check (7-point gate)
#
# Validates that ODF is healthy and functional in the OPP interop cluster.
# Replaces the former interop-tests-ocs-tests step which ran single-product
# ODF acceptance tests unrelated to cross-product interop.
#
# Produces JUnit XML consumed by Prow / Sippy / TestGrid.
# ---------------------------------------------------------------------------

ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
NOOBAA_S3_TIMEOUT="${NOOBAA_S3_TIMEOUT:-30}"

typeset junitFile="${ARTIFACT_DIR}/junit_odf_health.xml"

typeset -a tcNamesArr=()
typeset -a tcResultsArr=()
typeset -a tcMessagesArr=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

AddResult() {
    typeset name="${1:-}"; (($#)) && shift
    typeset result="${1:-}"; (($#)) && shift
    typeset message="${1:-}"; (($#)) && shift
    tcNamesArr+=("${name}")
    tcResultsArr+=("${result}")
    tcMessagesArr+=("${message}")
    true
}

XmlEscape() {
    typeset text="${1:-}"; (($#)) && shift
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&apos;}"
    printf '%s' "${text}"
    true
}

WriteJunit() {
    typeset -i total=${#tcNamesArr[@]}
    typeset -i failCount=0
    typeset -i skipCount=0
    for r in "${tcResultsArr[@]}"; do
        if [[ "${r}" == "fail" ]]; then
            (( failCount++ )) || true
        elif [[ "${r}" == "skip" ]]; then
            (( skipCount++ )) || true
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"odf-health\" tests=\"${total}\" failures=\"${failCount}\" skipped=\"${skipCount}\">"
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"odf-health\" name=\"${name}\">"
            if [[ "${tcResultsArr[$i]}" == "fail" ]]; then
                typeset msg=""
                msg="$(XmlEscape "${tcMessagesArr[$i]}")"
                echo "    <failure message=\"${msg}\"></failure>"
            elif [[ "${tcResultsArr[$i]}" == "skip" ]]; then
                typeset msg=""
                msg="$(XmlEscape "${tcMessagesArr[$i]}")"
                echo "    <skipped message=\"${msg}\"/>"
            fi
            echo "  </testcase>"
        done
        echo "</testsuite>"
    } > "${junitFile}"
    : "JUnit XML written to ${junitFile}"
}

# shellcheck disable=SC2317
CollectExitArtifacts() {
    : "Collecting ODF diagnostics..."
    oc get csv -n "${ODF_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/odf-csvs.yaml" || true
    oc get storagecluster -n "${ODF_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/storagecluster.yaml" || true
    oc get cephcluster -n "${ODF_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/cephcluster.yaml" || true
    oc get noobaa -n "${ODF_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/noobaa.yaml" || true
    oc get sc -o yaml > "${ARTIFACT_DIR}/storageclasses.yaml" || true
}

trap CollectExitArtifacts EXIT

# ---------------------------------------------------------------------------
# Check 1: ODF Operator CSV in Succeeded phase
# ---------------------------------------------------------------------------

CheckOdfCsv() {
    : "=== Check 1: ODF Operator CSV ==="

    typeset csvPhase=""
    if ! csvPhase="$(oc get csv -n "${ODF_NAMESPACE}" -o json | jq -r '
        [.items[] | select(.metadata.name | test("^(odf-|ocs-)operator"))] |
        first | .status.phase // "NotFound"
    ')"; then
        AddResult "odf-csv-phase" "fail" "Failed to query ODF CSVs in ${ODF_NAMESPACE}"
        return
    fi

    if [[ "${csvPhase}" == "Succeeded" ]]; then
        : "PASS: ODF CSV phase=Succeeded"
        AddResult "odf-csv-phase" "pass"
    elif [[ "${csvPhase}" == "NotFound" ]]; then
        AddResult "odf-csv-phase" "fail" "No ODF/OCS operator CSV found in ${ODF_NAMESPACE}"
    else
        AddResult "odf-csv-phase" "fail" "ODF CSV phase=${csvPhase} (expected Succeeded)"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 2: StorageCluster phase == Ready
# ---------------------------------------------------------------------------

CheckStorageCluster() {
    : "=== Check 2: StorageCluster Ready ==="

    typeset scPhase=""
    if ! scPhase="$(oc get storagecluster -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.phase // "NotFound"
    ')"; then
        AddResult "storagecluster-ready" "fail" "Failed to query StorageCluster"
        return
    fi

    if [[ "${scPhase}" == "Ready" ]]; then
        : "PASS: StorageCluster phase=Ready"
        AddResult "storagecluster-ready" "pass"
    elif [[ "${scPhase}" == "NotFound" ]]; then
        AddResult "storagecluster-ready" "fail" "No StorageCluster found in ${ODF_NAMESPACE}"
    else
        AddResult "storagecluster-ready" "fail" "StorageCluster phase=${scPhase} (expected Ready)"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 3: CephCluster health == HEALTH_OK or HEALTH_WARN
# ---------------------------------------------------------------------------

CheckCephCluster() {
    : "=== Check 3: CephCluster health ==="

    typeset cephHealth=""
    if ! cephHealth="$(oc get cephcluster -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.ceph.health // "NotFound"
    ')"; then
        AddResult "cephcluster-health" "fail" "Failed to query CephCluster"
        return
    fi

    if [[ "${cephHealth}" == "HEALTH_OK" || "${cephHealth}" == "HEALTH_WARN" ]]; then
        : "PASS: CephCluster health=${cephHealth}"
        AddResult "cephcluster-health" "pass"
    elif [[ "${cephHealth}" == "NotFound" ]]; then
        AddResult "cephcluster-health" "fail" "No CephCluster found in ${ODF_NAMESPACE}"
    else
        AddResult "cephcluster-health" "fail" "CephCluster health=${cephHealth} (expected HEALTH_OK or HEALTH_WARN)"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 4: Default StorageClasses available (ceph-rbd, cephfs)
# ---------------------------------------------------------------------------

CheckStorageClasses() {
    : "=== Check 4: StorageClasses ==="
    typeset failMsg=""

    for scName in ocs-storagecluster-ceph-rbd ocs-storagecluster-cephfs; do
        if ! oc get sc "${scName}" &>/dev/null; then
            if [[ -n "${failMsg}" ]]; then
                failMsg="${failMsg}; StorageClass ${scName} not found"
            else
                failMsg="StorageClass ${scName} not found"
            fi
        else
            : "PASS: StorageClass ${scName} exists"
        fi
    done

    if [[ -z "${failMsg}" ]]; then
        AddResult "storageclasses-available" "pass"
    else
        AddResult "storageclasses-available" "fail" "${failMsg}"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 5: PVC provisionable (create, bind, delete)
# ---------------------------------------------------------------------------

CheckPvcProvision() {
    : "=== Check 5: PVC provisioning ==="

    typeset pvcName="odf-health-check-pvc-$$"
    typeset pvcYaml
    pvcYaml=$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvcName}
  namespace: ${ODF_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ocs-storagecluster-ceph-rbd
EOF
)

    if ! echo "${pvcYaml}" | oc apply -f - 2>/dev/null; then
        AddResult "pvc-provision" "fail" "Failed to create test PVC"
        return
    fi

    typeset -i maxWait=60
    typeset -i elapsed=0
    typeset phase=""
    while (( elapsed < maxWait )); do
        phase="$(oc get pvc "${pvcName}" -n "${ODF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
        if [[ "${phase}" == "Bound" ]]; then
            break
        fi
        sleep 5
        (( elapsed += 5 )) || true
    done

    oc delete pvc "${pvcName}" -n "${ODF_NAMESPACE}" --wait=false 2>/dev/null || true

    if [[ "${phase}" == "Bound" ]]; then
        : "PASS: PVC provisioned and bound in ${elapsed}s"
        AddResult "pvc-provision" "pass"
    else
        AddResult "pvc-provision" "fail" "PVC did not bind within ${maxWait}s (phase=${phase:-unknown})"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 6: NooBaa system Ready + S3 put/get/delete functional check
# ---------------------------------------------------------------------------

CheckNoobaa() {
    : "=== Check 6: NooBaa S3 functional ==="

    typeset nbPhase=""
    if ! nbPhase="$(oc get noobaa -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.phase // "NotFound"
    ')"; then
        AddResult "noobaa-s3-functional" "fail" "Failed to query NooBaa"
        return
    fi

    if [[ "${nbPhase}" == "NotFound" ]]; then
        AddResult "noobaa-s3-functional" "fail" "No NooBaa system found in ${ODF_NAMESPACE}"
        return
    fi

    if [[ "${nbPhase}" != "Ready" ]]; then
        AddResult "noobaa-s3-functional" "fail" "NooBaa phase=${nbPhase} (expected Ready)"
        return
    fi

    : "NooBaa phase=Ready, running S3 functional check..."

    typeset s3Endpoint="" accessKey="" secretKey=""
    s3Endpoint="$(oc get noobaa -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.services.serviceS3.internalDNS[0] // empty
    ')" || true

    if [[ -z "${s3Endpoint}" ]]; then
        s3Endpoint="https://s3.${ODF_NAMESPACE}.svc:443"
    fi

    typeset secretName=""
    secretName="$(oc get noobaa -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.accounts.admin.secretRef.name // "noobaa-admin"
    ')" || true

    set +x
    if ! accessKey="$(oc get secret "${secretName}" -n "${ODF_NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"; then
        set -x
        AddResult "noobaa-s3-functional" "fail" "Cannot read NooBaa admin credentials"
        return
    fi
    if ! secretKey="$(oc get secret "${secretName}" -n "${ODF_NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"; then
        set -x
        AddResult "noobaa-s3-functional" "fail" "Cannot read NooBaa admin credentials"
        return
    fi

    typeset testKey="health-check-test"
    typeset testData=""
    testData="odf-health-$(date +%s)"

    typeset podName="odf-health-s3-check-$$"
    typeset s3Result=""
    if s3Result="$(oc run "${podName}" -n "${ODF_NAMESPACE}" \
        --image=amazon/aws-cli:latest \
        --restart=Never \
        --rm=true \
        --attach=true \
        --timeout="${NOOBAA_S3_TIMEOUT}s" \
        --command -- sh -c "$(cat <<EOF
export AWS_ACCESS_KEY_ID='${accessKey}'
export AWS_SECRET_ACCESS_KEY='${secretKey}'
S3_ENDPOINT='${s3Endpoint}'
TEST_KEY='${testKey}'
TEST_DATA='${testData}'
echo "\${TEST_DATA}" | aws --endpoint-url "\${S3_ENDPOINT}" --no-verify-ssl s3 cp - "s3://first.bucket/\${TEST_KEY}" 2>/dev/null && \
RETRIEVED=\$(aws --endpoint-url "\${S3_ENDPOINT}" --no-verify-ssl s3 cp "s3://first.bucket/\${TEST_KEY}" - 2>/dev/null) && \
aws --endpoint-url "\${S3_ENDPOINT}" --no-verify-ssl s3 rm "s3://first.bucket/\${TEST_KEY}" 2>/dev/null && \
if [ "\${RETRIEVED}" = "\${TEST_DATA}" ]; then echo "S3_CHECK_PASS"; else echo "S3_CHECK_FAIL: data mismatch"; fi
EOF
)" 2>/dev/null)"; then
        : "S3 check pod completed"
    else
        : "S3 check pod failed or timed out"
    fi
    set -x

    oc delete pod "${podName}" -n "${ODF_NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true

    if echo "${s3Result}" | grep -q "S3_CHECK_PASS"; then
        : "PASS: NooBaa S3 put/get/delete cycle succeeded"
        AddResult "noobaa-s3-functional" "pass"
    else
        typeset s3Msg="NooBaa S3 functional check failed"
        if echo "${s3Result}" | grep -q "S3_CHECK_FAIL"; then
            s3Msg="NooBaa S3: $(echo "${s3Result}" | grep "S3_CHECK_FAIL")"
        fi
        AddResult "noobaa-s3-functional" "fail" "${s3Msg}"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 7: Ceph overall health (via toolbox or CephCluster status)
# ---------------------------------------------------------------------------

CheckCephHealth() {
    : "=== Check 7: Ceph health detail ==="

    typeset cephDetail=""
    if ! cephDetail="$(oc get cephcluster -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.ceph.details // {} | to_entries[] |
        select(.value.severity != "HEALTH_OK") |
        "\(.key): \(.value.message // "unknown")"
    ')"; then
        AddResult "ceph-health-detail" "fail" "Failed to query CephCluster details"
        return
    fi

    typeset cephHealth=""
    cephHealth="$(oc get cephcluster -n "${ODF_NAMESPACE}" -o json | jq -r '
        .items[0].status.ceph.health // "unknown"
    ')" || true

    if [[ "${cephHealth}" == "HEALTH_OK" ]]; then
        : "PASS: Ceph health=HEALTH_OK"
        AddResult "ceph-health-detail" "pass"
    elif [[ "${cephHealth}" == "HEALTH_WARN" ]]; then
        : "PASS (warn): Ceph health=HEALTH_WARN: ${cephDetail}"
        AddResult "ceph-health-detail" "pass"
    else
        AddResult "ceph-health-detail" "fail" "Ceph health=${cephHealth}: ${cephDetail}"
    fi
    true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    : "ODF Health Check (7-point gate) starting"
    : "Namespace: ${ODF_NAMESPACE}"
    : "Artifacts dir: ${ARTIFACT_DIR}"

    CheckOdfCsv          || true
    CheckStorageCluster  || true
    CheckCephCluster     || true
    CheckStorageClasses  || true
    CheckPvcProvision    || true
    CheckNoobaa          || true
    CheckCephHealth      || true

    WriteJunit

    typeset -i hasAnyFail=0
    for r in "${tcResultsArr[@]}"; do
        if [[ "${r}" == "fail" ]]; then
            hasAnyFail=1
            break
        fi
    done

    if (( hasAnyFail )); then
        : "ODF Health Check: SOME CHECKS FAILED"
        exit 1
    fi

    : "ODF Health Check: ALL PASSED"
    exit 0
}

Main "$@"
