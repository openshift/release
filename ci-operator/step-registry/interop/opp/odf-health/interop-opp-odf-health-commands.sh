#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# ODF Health Check (7-point gate)
#
# Validates that ODF is healthy and functional in the OPP interop cluster.
# Replaces the former interop-tests-ocs-tests step which ran single-product
# ODF acceptance tests unrelated to cross-product interop.
#
# Produces JUnit XML consumed by Prow / Sippy / TestGrid.
# ---------------------------------------------------------------------------

typeset ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
typeset NOOBAA_S3_TIMEOUT="${NOOBAA_S3_TIMEOUT:-30}"
typeset ODF_READY_TIMEOUT="${ODF_READY_TIMEOUT:-720}"
typeset -ri MAX_ODF_READY_TIMEOUT=780
if (( ODF_READY_TIMEOUT > MAX_ODF_READY_TIMEOUT )); then
    printf '%s\n' "Warning: ODF_READY_TIMEOUT=${ODF_READY_TIMEOUT} exceeds maximum ${MAX_ODF_READY_TIMEOUT}s; clamping" >&2
    ODF_READY_TIMEOUT="${MAX_ODF_READY_TIMEOUT}"
fi

typeset junitFile="${ARTIFACT_DIR}/junit_odf_health.xml"

typeset -a tcNamesArr=()
typeset -a tcResultsArr=()
typeset -a tcMessagesArr=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function AddResult () {
    typeset name="${1:-}"; (($#)) && shift
    typeset result="${1:-}"; (($#)) && shift
    typeset message="${1:-}"; (($#)) && shift
    tcNamesArr+=("${name}")
    tcResultsArr+=("${result}")
    tcMessagesArr+=("${message}")
    true
}

function XmlEscape () {
    typeset text="${1:-}"; (($#)) && shift
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&apos;}"
    printf '%s' "${text}"
    true
}

function WriteJunit () {
    typeset -i total=${#tcNamesArr[@]}
    typeset -i failCount=0
    typeset -i skipCount=0
    typeset r=""
    for r in "${tcResultsArr[@]}"; do
        if [[ "${r}" == "fail" ]]; then
            (( ++failCount )) || true
        elif [[ "${r}" == "skip" ]]; then
            (( ++skipCount )) || true
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"lp-interop--ODF\" tests=\"${total}\" failures=\"${failCount}\" skipped=\"${skipCount}\">"
        typeset -i i=0
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"lp-interop--ODF\" name=\"${name}\">"
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
    true
}

# shellcheck disable=SC2317,SC2329
function CollectExitArtifacts () {
    : "Collecting ODF diagnostics..."
    oc get csv -n "${ODF_NAMESPACE}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/odf-csvs.yaml" || true
    oc get storagecluster -n "${ODF_NAMESPACE}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/storagecluster.yaml" || true
    oc get cephcluster -n "${ODF_NAMESPACE}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/cephcluster.yaml" || true
    oc get noobaa -n "${ODF_NAMESPACE}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/noobaa.yaml" || true
    oc get sc --ignore-not-found -o yaml > "${ARTIFACT_DIR}/storageclasses.yaml" || true
    true
}

# shellcheck disable=SC2317
_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

trap '{( CollectExitArtifacts; _propagate_junit; true )}' EXIT

# ---------------------------------------------------------------------------
# Check 1: ODF Operator CSV in Succeeded phase
# ---------------------------------------------------------------------------

function CheckOdfCsv () {
    : "=== Check 1: ODF Operator CSV ==="

    typeset csvPhase=""
    if ! csvPhase="$(oc get csv -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json,re; d=json.load(sys.stdin)
m=[i for i in d.get('items',[]) if re.match(r'^(odf-operator|ocs-operator)',i['metadata']['name'])]
print((m[0].get('status',{}).get('phase','NotFound')) if m else 'NotFound')
")"; then
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

function CheckStorageCluster () {
    : "=== Check 2: StorageCluster Ready ==="

    typeset scPhase=""
    if ! scPhase="$(oc get storagecluster -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['items'][0]['status'].get('phase','NotFound') if d.get('items') else 'NotFound')
")"; then
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

function CheckCephCluster () {
    : "=== Check 3: CephCluster health ==="

    typeset cephHealth=""
    if ! cephHealth="$(oc get cephcluster -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['items'][0].get('status',{}).get('ceph',{}).get('health','NotFound') if d.get('items') else 'NotFound')
")"; then
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

function CheckStorageClasses () {
    : "=== Check 4: StorageClasses ==="
    typeset failMsg=""
    typeset scName=""

    for scName in ocs-storagecluster-ceph-rbd ocs-storagecluster-cephfs; do
        if ! oc get sc "${scName}" -o name 2>/dev/null; then
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

function CheckPvcProvision () {
    : "=== Check 5: PVC provisioning (RBD + CephFS) ==="

    typeset -a scTests=("ocs-storagecluster-ceph-rbd" "ocs-storagecluster-cephfs")
    typeset -a scModes=("ReadWriteOnce" "ReadWriteMany")
    typeset -i idx=0

    for idx in "${!scTests[@]}"; do
        typeset scName="${scTests[$idx]}"
        typeset accessMode="${scModes[$idx]}"
        typeset testId="pvc-provision-${scName##*-}"
        typeset pvcName="odf-health-${scName##*-}-${RANDOM}"
        typeset pvcYaml=""
        pvcYaml=$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvcName}
  namespace: ${ODF_NAMESPACE}
spec:
  accessModes:
    - ${accessMode}
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${scName}
EOF
)

        if ! echo "${pvcYaml}" | oc apply -f -; then
            AddResult "${testId}" "fail" "Failed to create test PVC for ${scName}"
            continue
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
            : "PASS: ${scName} PVC bound in ${elapsed}s"
            AddResult "${testId}" "pass"
        else
            AddResult "${testId}" "fail" "${scName} PVC did not bind within ${maxWait}s (phase=${phase:-unknown})"
        fi
    done
    true
}

# ---------------------------------------------------------------------------
# Check 6: NooBaa system Ready + S3 put/get/delete functional check
# ---------------------------------------------------------------------------

function CheckNoobaa () {
    : "=== Check 6: NooBaa S3 functional ==="

    typeset nbPhase=""
    if ! nbPhase="$(oc get noobaa -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['items'][0]['status'].get('phase','NotFound') if d.get('items') else 'NotFound')
")"; then
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

    : "NooBaa phase=Ready, creating OBC for S3 functional check..."

    typeset obcName="odf-health-obc-${RANDOM}"
    typeset obcYaml=""
    obcYaml=$(cat <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${obcName}
  namespace: ${ODF_NAMESPACE}
spec:
  generateBucketName: odf-health-check
  storageClassName: openshift-storage.noobaa.io
EOF
)

    if ! echo "${obcYaml}" | oc apply -f -; then
        AddResult "noobaa-s3-functional" "fail" "Failed to create ObjectBucketClaim"
        return
    fi

    typeset -i maxWait=60
    typeset -i elapsed=0
    typeset obcPhase=""
    while (( elapsed < maxWait )); do
        obcPhase="$(oc get obc "${obcName}" -n "${ODF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
        if [[ "${obcPhase}" == "Bound" ]]; then
            break
        fi
        sleep 5
        (( elapsed += 5 )) || true
    done

    if [[ "${obcPhase}" != "Bound" ]]; then
        oc delete obc "${obcName}" -n "${ODF_NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true
        AddResult "noobaa-s3-functional" "fail" "OBC did not bind within ${maxWait}s (phase=${obcPhase:-unknown})"
        return
    fi

    typeset bucketName=""
    bucketName="$(oc get obc "${obcName}" -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.bucketName}' 2>/dev/null)" || true
    if [[ -z "${bucketName}" ]]; then
        oc delete obc "${obcName}" -n "${ODF_NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true
        AddResult "noobaa-s3-functional" "fail" "OBC bound but bucket name is empty"
        return
    fi
    typeset secretRef=""
    secretRef="$(oc get obc "${obcName}" -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.secretName}' 2>/dev/null)"
    if [[ -z "${secretRef}" ]]; then
        secretRef="${obcName}"
    fi

    typeset s3Endpoint=""
    s3Endpoint="$(oc get noobaa -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json; d=json.load(sys.stdin)
v=d['items'][0].get('status',{}).get('services',{}).get('serviceS3',{}).get('internalDNS',[])
print(v[0] if v else '')
")" || true
    if [[ -z "${s3Endpoint}" ]]; then
        s3Endpoint="https://s3.${ODF_NAMESPACE}.svc:443"
    fi

    typeset testKey="health-check-${RANDOM}"
    typeset testData=""
    testData="odf-health-$(date +%s)"

    typeset podName="odf-health-s3-check-${RANDOM}"
    typeset podManifest=""
    podManifest=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${podName}
  namespace: ${ODF_NAMESPACE}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
  volumes:
  - name: tmp
    emptyDir: {}
  containers:
  - name: s3check
    image: amazon/aws-cli:2.22.35
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    resources:
      limits:
        cpu: 200m
        memory: 256Mi
      requests:
        cpu: 100m
        memory: 128Mi
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    envFrom:
    - secretRef:
        name: ${secretRef}
    env:
    - name: S3_ENDPOINT
      value: "${s3Endpoint}"
    - name: BUCKET_NAME
      value: "${bucketName}"
    - name: TEST_KEY
      value: "${testKey}"
    - name: TEST_DATA
      value: "${testData}"
    command:
    - sh
    - -c
    - |
      echo "\${TEST_DATA}" | aws --endpoint-url "\${S3_ENDPOINT}" --no-verify-ssl s3 cp - "s3://\${BUCKET_NAME}/\${TEST_KEY}" 2>/dev/null && \
      RETRIEVED=\$(aws --endpoint-url "\${S3_ENDPOINT}" --no-verify-ssl s3 cp "s3://\${BUCKET_NAME}/\${TEST_KEY}" - 2>/dev/null) && \
      aws --endpoint-url "\${S3_ENDPOINT}" --no-verify-ssl s3 rm "s3://\${BUCKET_NAME}/\${TEST_KEY}" 2>/dev/null && \
      if [ "\${RETRIEVED}" = "\${TEST_DATA}" ]; then echo "S3_CHECK_PASS"; else echo "S3_CHECK_FAIL: data mismatch"; fi
  activeDeadlineSeconds: ${NOOBAA_S3_TIMEOUT}
EOF
)

    typeset s3Result=""
    typeset -i podWait=$(( NOOBAA_S3_TIMEOUT + 60 ))
    typeset xtrace=""
    [[ "${-}" == *x* ]] && xtrace="set -x" || xtrace="set +x"
    set +x
    if echo "${podManifest}" | oc apply -f -; then
        ${xtrace}
        if ! oc wait pod "${podName}" -n "${ODF_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${podWait}s" 2>/dev/null; then
            : "Pod did not succeed within ${podWait}s, collecting diagnostics"
            oc get pod "${podName}" -n "${ODF_NAMESPACE}" -o yaml --ignore-not-found || true
            oc describe pod "${podName}" -n "${ODF_NAMESPACE}" || true
        fi
        s3Result="$(oc logs "${podName}" -n "${ODF_NAMESPACE}" 2>/dev/null || echo "")"
    else
        ${xtrace}
    fi

    oc delete pod "${podName}" -n "${ODF_NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true
    oc delete obc "${obcName}" -n "${ODF_NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true

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

function CheckCephHealth () {
    : "=== Check 7: Ceph health detail ==="

    typeset cephDetail=""
    if ! cephDetail="$(oc get cephcluster -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json; d=json.load(sys.stdin)
details=d['items'][0].get('status',{}).get('ceph',{}).get('details',{}) if d.get('items') else {}
for k,v in details.items():
 if v.get('severity')!='HEALTH_OK': print(f\"{k}: {v.get('message','unknown')}\")
")"; then
        AddResult "ceph-health-detail" "fail" "Failed to query CephCluster details"
        return
    fi

    typeset cephHealth=""
    cephHealth="$(oc get cephcluster -n "${ODF_NAMESPACE}" -o json | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['items'][0].get('status',{}).get('ceph',{}).get('health','unknown') if d.get('items') else 'unknown')
")" || true

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
# Wait for ODF subsystems to reach Ready (handles vSphere slow convergence)
# ---------------------------------------------------------------------------

function WaitForOdfReady () {
    typeset -i timeout="${ODF_READY_TIMEOUT}"
    typeset -i deadline=$(( SECONDS + timeout ))
    typeset -i pollInterval=15

    : "Waiting up to ${timeout}s for StorageCluster and NooBaa to reach Ready..."

    typeset scPhase="" nbPhase=""
    while (( SECONDS < deadline )); do
        typeset -i remaining=$(( deadline - SECONDS ))
        (( remaining < 1 )) && remaining=1

        scPhase="$(oc get storagecluster -n "${ODF_NAMESPACE}" -o json --request-timeout="${remaining}s" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['items'][0]['status'].get('phase','') if d.get('items') else '')
" 2>/dev/null)" || scPhase=""

        remaining=$(( deadline - SECONDS ))
        (( remaining < 1 )) && remaining=1

        nbPhase="$(oc get noobaa -n "${ODF_NAMESPACE}" -o json --request-timeout="${remaining}s" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d['items'][0]['status'].get('phase','') if d.get('items') else '')
" 2>/dev/null)" || nbPhase=""

        typeset -i elapsed=$(( SECONDS - (deadline - timeout) ))

        if [[ "${scPhase}" == "Ready" && "${nbPhase}" == "Ready" ]]; then
            : "ODF ready after ${elapsed}s (StorageCluster=Ready, NooBaa=Ready)"
            return 0
        fi

        if [[ "${scPhase}" == "Ready" && -z "${nbPhase}" ]]; then
            : "StorageCluster Ready, no NooBaa deployed (acceptable)"
            return 0
        fi

        : "Waiting... StorageCluster=${scPhase:-unknown}, NooBaa=${nbPhase:-unknown} (${elapsed}/${timeout}s)"
        sleep "${pollInterval}"
    done

    typeset -i elapsed=$(( SECONDS - (deadline - timeout) ))
    : "ODF did not reach Ready within ${elapsed}s (StorageCluster=${scPhase:-unknown}, NooBaa=${nbPhase:-unknown})"
    return 1
}

# ---------------------------------------------------------------------------
# Main: probe ODF installation, wait for readiness, run health checks
# ---------------------------------------------------------------------------

# Returns 0 if ODF/OCS CSV exists in ODF_NAMESPACE, 1 if absent, 2 on error.
function CheckOdfInstalled () {
    if ! oc get namespace "${ODF_NAMESPACE}" >/dev/null 2>&1; then
        return 1
    fi
    typeset csvJson=""
    typeset -i ocExit=0
    csvJson="$(oc get csv -n "${ODF_NAMESPACE}" -o json 2>/dev/null)" || ocExit=$?
    if (( ocExit != 0 )); then
        printf '%s\n' "Error: oc get csv failed (exit ${ocExit}) in ${ODF_NAMESPACE}" >&2
        return 2
    fi
    if [[ -z "${csvJson}" ]]; then
        printf '%s\n' "Error: oc get csv returned empty output in ${ODF_NAMESPACE}" >&2
        return 2
    fi
    typeset csvCount=""
    if ! csvCount="$(printf '%s' "${csvJson}" | python3 -c "
import sys,json,re; d=json.load(sys.stdin)
print(len([i for i in d.get('items',[]) if re.match(r'^(odf-operator|ocs-operator)',i['metadata']['name'])]))
")"; then
        printf '%s\n' "Error: failed to parse CSV JSON from ${ODF_NAMESPACE}" >&2
        return 2
    fi
    if [[ "${csvCount}" -gt 0 ]]; then
        return 0
    fi
    return 1
}

function Main () {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    : "ODF Health Check (7-point gate) starting"
    : "Namespace: ${ODF_NAMESPACE}"
    : "Artifacts dir: ${ARTIFACT_DIR}"

    typeset -i odfProbeResult=0
    CheckOdfInstalled || odfProbeResult=$?
    if (( odfProbeResult == 2 )); then
        : "ODF Health Check: PROBE ERROR (cannot determine ODF state)"
        exit 1
    fi
    if (( odfProbeResult == 1 )); then
        typeset skipMsg="ODF is not installed (no ODF/OCS CSV in ${ODF_NAMESPACE})"
        typeset -a checkNames=("odf-csv-phase" "storagecluster-ready" "cephcluster-health"
            "storageclasses-available" "pvc-provision-rbd" "pvc-provision-cephfs"
            "noobaa-s3-functional" "ceph-health-detail")
        typeset name=""
        for name in "${checkNames[@]}"; do
            AddResult "${name}" "skip" "${skipMsg}"
        done
        WriteJunit
        : "ODF Health Check: ALL SKIPPED (ODF not installed)"
        exit 0
    fi

    if ! WaitForOdfReady; then
        : "ODF subsystems did not converge within ${ODF_READY_TIMEOUT}s; running checks to capture current state"
    fi

    CheckOdfCsv          || true
    CheckStorageCluster  || true
    CheckCephCluster     || true
    CheckStorageClasses  || true
    CheckPvcProvision    || true
    CheckNoobaa          || true
    CheckCephHealth      || true

    WriteJunit

    typeset -i hasAnyFail=0
    typeset r=""
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

