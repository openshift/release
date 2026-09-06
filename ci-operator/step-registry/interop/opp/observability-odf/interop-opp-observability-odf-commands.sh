#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# ACM Observability + ODF Interop Validation (6-point gate)
#
# Validates that ACM's observability stack (Thanos) correctly uses
# ODF-provided object storage (Ceph RGW or NooBaa S3) as its backend.
# This is a cross-product interop test exercising the ACM <-> ODF boundary.
#
# Produces JUnit XML consumed by Prow / Sippy / TestGrid.
# ---------------------------------------------------------------------------

typeset acmNamespace="${ACM_NAMESPACE:-open-cluster-management}"
typeset obsNamespace="${OBS_NAMESPACE:-open-cluster-management-observability}"
typeset odfNamespace="${ODF_NAMESPACE:-openshift-storage}"

typeset junitFile="${ARTIFACT_DIR}/junit_observability_odf.xml"

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
            (( ++failCount ))
        elif [[ "${r}" == "skip" ]]; then
            (( ++skipCount ))
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"lp-interop--ACM-OBS-ODF\" tests=\"${total}\" failures=\"${failCount}\" skipped=\"${skipCount}\">"
        typeset -i i=0
        for i in "${!tcNamesArr[@]}"; do
            typeset name=""
            name="$(XmlEscape "${tcNamesArr[$i]}")"
            echo "  <testcase classname=\"lp-interop--ACM-OBS-ODF\" name=\"${name}\">"
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
    : "Collecting observability + ODF diagnostics..."
    oc get multiclusterobservabilities.observability.open-cluster-management.io --all-namespaces --ignore-not-found -o yaml > "${ARTIFACT_DIR}/mco.yaml" || true
    oc get pods -n "${obsNamespace}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/obs-pods.yaml" || true
    oc get obc -n "${obsNamespace}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/obs-obc.yaml" || true
    oc get secret -n "${obsNamespace}" --ignore-not-found -o name > "${ARTIFACT_DIR}/obs-secrets-list.txt" || true
    oc get cephobjectstore -n "${odfNamespace}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/cephobjectstore.yaml" || true
    oc get pods -n "${odfNamespace}" -l app=rook-ceph-rgw --ignore-not-found -o yaml > "${ARTIFACT_DIR}/rgw-pods.yaml" || true
    oc get noobaa -n "${odfNamespace}" --ignore-not-found -o yaml > "${ARTIFACT_DIR}/noobaa.yaml" || true
    true
}

_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}

trap '{( CollectExitArtifacts; _propagate_junit; true )}' EXIT

# ---------------------------------------------------------------------------
# Check 1: ODF Ceph RGW infrastructure ready
# ---------------------------------------------------------------------------

function CheckRgwReady () {
    : "=== Check 1: ODF Ceph RGW infrastructure ==="

    typeset rgwPhase=""
    typeset rgwJson="" rgwErr=""
    if ! rgwJson="$(oc get cephobjectstore -n "${odfNamespace}" -o json 2>&1)"; then
        rgwErr="${rgwJson}"
        if [[ "${rgwErr}" == *"the server doesn"*"have a resource type"* || "${rgwErr}" == *"NotFound"* ]]; then
            rgwPhase="NotFound"
        else
            AddResult "odf-storage-ready" "fail" "Failed to query CephObjectStore: ${rgwErr}"
            return
        fi
    elif ! rgwPhase="$(printf '%s' "${rgwJson}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('items',[])
if not items:
    print('NotFound')
else:
    print(items[0].get('status',{}).get('phase','Unknown'))
")"; then
        AddResult "odf-storage-ready" "fail" "Failed to query CephObjectStore"
        return
    fi

    if [[ "${rgwPhase}" == "NotFound" ]]; then
        typeset noobaaJson=""
        noobaaJson="$(oc get noobaa -n "${odfNamespace}" -o json)" || true
        typeset noobaaPhase=""
        if [[ -n "${noobaaJson}" ]]; then
            noobaaPhase="$(printf '%s' "${noobaaJson}" | python3 -c "
import sys,json
items=json.load(sys.stdin).get('items',[])
print(items[0].get('status',{}).get('phase','') if items else '')
")"
        fi
        if [[ "${noobaaPhase}" == "Ready" ]]; then
            AddResult "odf-storage-ready" "pass" "NooBaa Ready (RGW not deployed)"
        elif [[ -n "${noobaaPhase}" ]]; then
            AddResult "odf-storage-ready" "fail" "NooBaa phase=${noobaaPhase} (expected Ready); RGW not deployed"
        else
            AddResult "odf-storage-ready" "skip" "Neither CephObjectStore nor NooBaa found in ${odfNamespace}"
        fi
        return
    fi

    typeset failMsg=""
    if [[ "${rgwPhase}" != "Ready" ]]; then
        failMsg="CephObjectStore phase=${rgwPhase} (expected Ready)"
    fi

    typeset rgwPods=""
    rgwPods="$(oc get pods -n "${odfNamespace}" -l app=rook-ceph-rgw \
        --field-selector=status.phase=Running --no-headers)" || true
    typeset rgwPodCount=""
    rgwPodCount="$(printf '%s' "${rgwPods}" | awk 'END{print NR}')"

    if [[ "${rgwPodCount}" -eq 0 ]]; then
        typeset rgwMsg="No rook-ceph-rgw pods Running in ${odfNamespace}"
        if [[ -n "${failMsg}" ]]; then
            failMsg="${failMsg}; ${rgwMsg}"
        else
            failMsg="${rgwMsg}"
        fi
    fi

    typeset scExists=""
    scExists="$(oc get sc ocs-storagecluster-ceph-rgw -o name)" || true
    if [[ -z "${scExists}" ]]; then
        typeset scMsg="StorageClass ocs-storagecluster-ceph-rgw not found"
        if [[ -n "${failMsg}" ]]; then
            failMsg="${failMsg}; ${scMsg}"
        else
            failMsg="${scMsg}"
        fi
    fi

    if [[ -z "${failMsg}" ]]; then
        : "PASS: CephObjectStore Ready, RGW pods Running, StorageClass exists"
        AddResult "odf-storage-ready" "pass"
    else
        AddResult "odf-storage-ready" "fail" "${failMsg}"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 2: MultiClusterObservability CR exists and is Ready
# ---------------------------------------------------------------------------

function CheckMcoReady () {
    : "=== Check 2: MultiClusterObservability CR ==="

    typeset mcoStatus=""
    if ! mcoStatus="$(oc get multiclusterobservabilities.observability.open-cluster-management.io \
        --all-namespaces -o json | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('items',[])
if not items:
    print('NotFound')
else:
    conds=items[0].get('status',{}).get('conditions',[])
    ready=[c for c in conds if c.get('type')=='Ready']
    print(ready[0].get('status','Unknown') if ready else 'NoCondition')
")"; then
        AddResult "mco-ready" "fail" "Failed to query MultiClusterObservability CR"
        return
    fi

    if [[ "${mcoStatus}" == "True" ]]; then
        : "PASS: MultiClusterObservability Ready=True"
        AddResult "mco-ready" "pass"
    elif [[ "${mcoStatus}" == "NotFound" ]]; then
        AddResult "mco-ready" "skip" "MultiClusterObservability CR not found; observability not deployed"
    else
        AddResult "mco-ready" "fail" "MultiClusterObservability Ready=${mcoStatus} (expected True)"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 3: Object storage secret references ODF-backed endpoint
# ---------------------------------------------------------------------------

function CheckStorageEndpoint () {
    : "=== Check 3: Object storage endpoint ==="

    typeset storageConfig=""
    if ! storageConfig="$(oc get multiclusterobservabilities.observability.open-cluster-management.io \
        --all-namespaces -o json | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('items',[])
if not items:
    print('')
else:
    spec=items[0].get('spec',{})
    storage=spec.get('storageConfig',{}).get('metricObjectStorage',{})
    name=storage.get('name','')
    key=storage.get('key','thanos.yaml')
    print(f'{name}|{key}' if name else '')
")"; then
        AddResult "storage-endpoint" "fail" "Failed to read MCO storage config"
        return
    fi

    if [[ -z "${storageConfig}" ]]; then
        AddResult "storage-endpoint" "skip" "No metricObjectStorage secret configured in MCO"
        return
    fi

    typeset secretName="${storageConfig%%|*}"
    typeset secretKey="${storageConfig#*|}"

    typeset secretJson=""
    secretJson="$(oc get secret "${secretName}" -n "${obsNamespace}" -o json 2>/dev/null)" || true
    if [[ -z "${secretJson}" ]]; then
        AddResult "storage-endpoint" "fail" "Secret ${secretName} not found in ${obsNamespace}"
        return
    fi
    typeset endpointCheck=""
    if [[ -n "${secretJson}" ]]; then
        endpointCheck="$(printf '%s' "${secretJson}" | python3 -c "
import sys,json,base64,re
sys.tracebacklimit=0
d=json.load(sys.stdin)
target_key=sys.argv[1] if len(sys.argv)>1 else 'thanos.yaml'
raw=d.get('data',{}).get(target_key,'')
if not raw:
    print('no-endpoint')
    sys.exit(0)
try:
    content=base64.b64decode(raw).decode('utf-8','replace')
except Exception:
    print('no-endpoint')
    sys.exit(0)
endpoint=''
try:
    import yaml
    cfg=yaml.safe_load(content)
    endpoint=cfg.get('config',{}).get('endpoint','') if isinstance(cfg,dict) else ''
except Exception:
    m=re.search(r'endpoint:\s*(.+)',content)
    endpoint=m.group(1).strip() if m else ''
del content
if not endpoint:
    print('no-endpoint')
    sys.exit(0)
odf_pat=re.compile(r'(openshift-storage|noobaa|ceph|rgw|rook|ocs|mcg)',re.IGNORECASE)
print('odf-backed' if odf_pat.search(endpoint) else 'external')
" "${secretKey}")"
    fi

    if [[ "${endpointCheck}" == "no-endpoint" || -z "${endpointCheck}" ]]; then
        AddResult "storage-endpoint" "fail" "Secret ${secretName} exists but no endpoint config found in key ${secretKey}"
        return
    fi

    if [[ "${endpointCheck}" == "odf-backed" ]]; then
        AddResult "storage-endpoint" "pass"
    else
        AddResult "storage-endpoint" "fail" "Storage endpoint does not reference ODF-backed service"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 4: Thanos components healthy
# ---------------------------------------------------------------------------

function CheckThanosHealth () {
    : "=== Check 4: Thanos components healthy ==="

    if ! oc get namespace "${obsNamespace}" -o name; then
        AddResult "thanos-health" "skip" "Observability namespace ${obsNamespace} does not exist"
        return
    fi

    typeset failMsg=""
    typeset -i foundCount=0
    typeset -i discoveryErrors=0
    typeset -a missingComponents=()

    typeset -a componentNames=("thanos-receive"     "thanos-compact"     "thanos-store"       "thanos-query"       "alertmanager"       "rbac-query-proxy")
    typeset -a componentLabels=("app=thanos-receive" "app=thanos-compact" "app=thanos-store"   "app=thanos-query"   "alertmanager=observability" "app=rbac-query-proxy")

    typeset -i idx=0
    for idx in "${!componentNames[@]}"; do
        typeset component="${componentNames[$idx]}"
        typeset labelSelector="${componentLabels[$idx]}"

        typeset podList=""
        if ! podList="$(oc get pods -n "${obsNamespace}" -l "${labelSelector}" \
            --no-headers 2>&1)"; then
            (( ++discoveryErrors ))
            podList=""
        fi

        if [[ -z "${podList}" ]]; then
            typeset allPods=""
            if ! allPods="$(oc get pods -n "${obsNamespace}" \
                --no-headers 2>&1)"; then
                (( ++discoveryErrors ))
                allPods=""
            fi
            podList="$(printf '%s' "${allPods}" | awk -v pat="^${component}" '$0 ~ pat')"
        fi

        typeset podCount=""
        podCount="$(printf '%s' "${podList}" | awk 'NF {c++} END{print c+0}')"

        if [[ "${podCount}" -eq 0 ]]; then
            missingComponents+=("${component}")
            continue
        fi

        (( ++foundCount ))

        typeset notReady=""
        notReady="$(printf '%s' "${podList}" \
            | awk '$3 != "Running" && $3 != "Completed" {print $1 ":" $3}')"

        if [[ -n "${notReady}" ]]; then
            typeset compMsg="${component}: ${notReady//$'\n'/, }"
            if [[ -n "${failMsg}" ]]; then
                failMsg="${failMsg}; ${compMsg}"
            else
                failMsg="${compMsg}"
            fi
        fi
    done

    if (( foundCount == 0 && discoveryErrors > 0 )); then
        AddResult "thanos-health" "fail" "Pod discovery failed (${discoveryErrors} API errors) in ${obsNamespace}"
    elif (( foundCount == 0 )); then
        AddResult "thanos-health" "skip" "No Thanos/observability components found in ${obsNamespace}; observability not deployed"
    elif [[ -n "${failMsg}" ]]; then
        AddResult "thanos-health" "fail" "Unhealthy Thanos components: ${failMsg}"
    elif (( ${#missingComponents[@]} > 0 && discoveryErrors > 0 )); then
        AddResult "thanos-health" "fail" "Missing components (${discoveryErrors} API errors during discovery): ${missingComponents[*]}"
    elif (( ${#missingComponents[@]} > 0 )); then
        AddResult "thanos-health" "fail" "Missing components: ${missingComponents[*]}"
    else
        AddResult "thanos-health" "pass"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 5: ObjectBucketClaim bound (if used by observability)
# ---------------------------------------------------------------------------

function CheckObcBound () {
    : "=== Check 5: Observability ObjectBucketClaim ==="

    typeset obcList=""
    obcList="$(oc get obc -n "${obsNamespace}" -o json 2>/dev/null)" || true

    typeset obcItemCount=0
    obcItemCount="$(printf '%s' "${obcList}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d.get('items',[])))
except Exception:
    print(0)
")"

    if [[ "${obcItemCount}" -eq 0 ]]; then
        typeset odfObcJson=""
        odfObcJson="$(oc get obc -n "${odfNamespace}" -o json 2>/dev/null)" || true
        obcList="$(printf '%s' "${odfObcJson}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    obs=[i for i in d.get('items',[]) if 'obs' in i['metadata'].get('name','').lower() or 'thanos' in i['metadata'].get('name','').lower()]
    print(json.dumps({'items':obs}))
except Exception:
    print(json.dumps({'items':[]}))
")"
        obcItemCount="$(printf '%s' "${obcList}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d.get('items',[])))
except Exception:
    print(0)
")"
    fi

    if [[ "${obcItemCount}" -eq 0 ]]; then
        AddResult "obc-bound" "skip" "No ObjectBucketClaim found for observability"
        return
    fi

    typeset obcStatus=""
    if ! obcStatus="$(echo "${obcList}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('items',[])
if not items:
    print('NotFound')
else:
    results=[]
    for i in items:
        name=i['metadata']['name']
        phase=i.get('status',{}).get('phase','Unknown')
        results.append(f'{name}={phase}')
    print(';'.join(results))
")"; then
        AddResult "obc-bound" "fail" "Failed to parse OBC status"
        return
    fi

    if [[ "${obcStatus}" == "NotFound" ]]; then
        AddResult "obc-bound" "skip" "No ObjectBucketClaim found for observability"
        return
    fi

    typeset unboundObcs=""
    unboundObcs="$(echo "${obcStatus}" | tr ';' '\n' | sed '/=Bound$/d')"

    if [[ -z "${unboundObcs}" ]]; then
        : "PASS: All observability OBCs bound: ${obcStatus}"
        AddResult "obc-bound" "pass"
    else
        AddResult "obc-bound" "fail" "Unbound OBCs: ${unboundObcs//$'\n'/, }"
    fi
    true
}

# ---------------------------------------------------------------------------
# Check 6: Thanos metrics query functional (basic data flow)
# ---------------------------------------------------------------------------

function ValidateThanosResponse () {
    typeset body="${1:-}"; (($#)) && shift
    typeset via="${1:-unknown}"; (($#)) && shift

    typeset validation=""
    validation="$(echo "${body}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print('parse-error')
    sys.exit(0)
if d.get('status')!='success':
    print('status=' + str(d.get('status','')))
    sys.exit(0)
data=d.get('data',{})
if data.get('resultType')!='vector':
    print('resultType=' + str(data.get('resultType','')))
    sys.exit(0)
result=data.get('result',[])
if not isinstance(result,list) or len(result)==0:
    print('empty-result')
    sys.exit(0)
print('ok')
")"

    if [[ "${validation}" == "ok" ]]; then
        AddResult "thanos-query" "pass"
    elif [[ "${validation}" == "empty-result" ]]; then
        AddResult "thanos-query" "fail" "Thanos query succeeded via ${via} but returned empty result vector"
    elif [[ "${validation}" == "parse-error" || -z "${validation}" ]]; then
        AddResult "thanos-query" "fail" "Thanos query via ${via} returned unparseable response"
    else
        AddResult "thanos-query" "fail" "Thanos query via ${via} returned ${validation}"
    fi
    true
}

function CheckThanosQuery () {
    : "=== Check 6: Thanos query functional ==="

    typeset routeJson=""
    routeJson="$(oc get routes -n "${obsNamespace}" -o json)" || true
    typeset queryRoute=""
    if [[ -n "${routeJson}" ]]; then
        queryRoute="$(printf '%s' "${routeJson}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
routes=d.get('items',[])
exact=[r for r in routes if r['metadata']['name']=='observability-thanos-query']
if exact:
    print(exact[0]['spec']['host'])
    sys.exit(0)
fuzzy=[r for r in routes if 'thanos' in r['metadata']['name'] and 'query' in r['metadata']['name']]
print(fuzzy[0]['spec']['host'] if fuzzy else '')
")"
    fi

    if [[ -z "${queryRoute}" ]]; then
        : "No external route found; trying internal query service"

        typeset queryFrontendJson=''
        queryFrontendJson="$(oc get pods -n "${obsNamespace}" \
            -l app.kubernetes.io/name=thanos-query-frontend -o json)" || true
        typeset queryFrontendPod=''
        if [[ -n "${queryFrontendJson}" ]]; then
            queryFrontendPod="$(printf '%s' "${queryFrontendJson}" | python3 -c "
import sys,json
items=json.load(sys.stdin).get('items',[])
print(items[0]['metadata']['name'] if items else '')
")"
        fi

        typeset queryResult=""
        if [[ -n "${queryFrontendPod}" ]]; then
            queryResult="$(oc exec --request-timeout=60s -n "${obsNamespace}" "${queryFrontendPod}" \
                -- curl -sk --connect-timeout 10 --max-time 30 \
                "http://localhost:9090/api/v1/query?query=up")" || true
        fi

        if [[ -z "${queryResult}" ]]; then
            typeset allQueryPods=''
            allQueryPods="$(oc get pods -n "${obsNamespace}" --no-headers)" || true
            typeset queryPod=''
            if [[ -n "${allQueryPods}" ]]; then
                queryPod="$(printf '%s' "${allQueryPods}" \
                    | awk '/thanos-query/ && !/frontend/ {print $1; exit}')"
            fi
            if [[ -n "${queryPod}" ]]; then
                queryResult="$(oc exec --request-timeout=60s -n "${obsNamespace}" "${queryPod}" \
                    -- curl -sk --connect-timeout 10 --max-time 30 \
                    "http://localhost:9090/api/v1/query?query=up")" || true
            fi
        fi

        if [[ -z "${queryResult}" ]]; then
            AddResult "thanos-query" "skip" "Cannot reach Thanos query endpoint (no route, exec failed)"
            return
        fi

        ValidateThanosResponse "${queryResult}" "exec"
        return
    fi

    typeset token=""
    token="$(oc whoami -t)" || true

    typeset responseBody=""
    typeset httpCode=""
    responseBody="$(curl -sk -w '\n%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "https://${queryRoute}/api/v1/query?query=up" \
        --max-time 30)" || true

    httpCode="$(echo "${responseBody}" | tail -1)"
    responseBody="$(echo "${responseBody}" | sed '$d')"

    if [[ "${httpCode}" != "200" ]]; then
        if [[ "${httpCode}" =~ ^(401|403)$ ]]; then
            AddResult "thanos-query" "fail" "Thanos query route auth failed (HTTP ${httpCode}); no data flow verified"
        else
            AddResult "thanos-query" "fail" "Thanos query route unreachable (HTTP ${httpCode:-timeout})"
        fi
        return
    fi

    ValidateThanosResponse "${responseBody}" "route"
    true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main () {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    : "ACM Observability + ODF Interop Validation starting"
    : "ACM namespace: ${acmNamespace}"
    : "Observability namespace: ${obsNamespace}"
    : "ODF namespace: ${odfNamespace}"
    : "Artifacts dir: ${ARTIFACT_DIR}"

    CheckRgwReady          || true
    CheckMcoReady          || true
    CheckStorageEndpoint   || true
    CheckThanosHealth      || true
    CheckObcBound          || true
    CheckThanosQuery       || true

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
        : "ACM Observability + ODF Interop: SOME CHECKS FAILED"
        exit 1
    fi

    : "ACM Observability + ODF Interop: ALL PASSED"
    exit 0
}

Main "$@"

