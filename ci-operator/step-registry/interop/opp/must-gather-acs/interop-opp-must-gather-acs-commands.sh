#!/bin/bash
# BASH-1: xtrace is what makes a CI failure diagnosable from the log
# alone; inherit_errexit stops an unguarded command substitution from
# swallowing a failure inside a subshell.
set -euxo pipefail; shopt -s inherit_errexit

# PRRT_kwDOBHvUUM65ui2E: fixture mode needs no CI environment, so a missing
# SHARED_DIR must not stop the script before the self-test dispatch.
if [[ -n "${SHARED_DIR:-}" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

# ─── oc error classification (shared) ───────────────────────────────────────
# A non-zero `oc get` exit means the query failed; what it failed with is read
# from the error text, because a registered resource type that the API server
# cannot answer for and an unregistered one are both non-zero exits. Only the
# API server's NotFound error shape counts as absence. A substring test on
# "not found" also matches a missing helper (`bash: oc: command not found`), a
# wrapper failure, or any client-side message carrying the phrase, which turns
# a broken capture path into confirmed absence and hides it from the capture
# assertion (a bare "not found" substring test). Callers keep their own
# three-way classification: notfound -> absent, no resource type -> absent,
# anything else -> probe_error/QUERY FAILED.
oc_notfound() { # oc_notfound <rc> <stderr-text>
  [[ ${1:-0} -ne 0 ]] || return 1
  grep -qE '(^|: )Error from server \(NotFound\)' <<< "${2:-}"
}

# _api_err_class <stderr-text>: collapse an API error to a fixed category so
# no server-controlled text reaches a log or an artifact.
_api_err_class() {
  case "$1" in
    "")                                                             echo "empty" ;;
    *[Uu]nauthorized*|*"must be logged in"*)                        echo "unauthorized" ;;
    *[Ff]orbidden*|*"cannot get"*|*"cannot list"*|*"cannot create"*) echo "forbidden" ;;
    *"not found"*|*NotFound*)                                       echo "not-found" ;;
    *[Tt]imeout*|*"unable to return a response"*)                   echo "timeout" ;;
    *"no such host"*|*"connection refused"*|*"connect: "*|*EOF*)     echo "transport-error" ;;
    *)                                                              echo "other" ;;
  esac
}

# _quiet_begin/_quiet_end: turn tracing off for a region and restore the
# caller's state, so a nested scope cannot re-enable tracing early.
_quiet_begin() { _quiet_was_on=0; case $- in *x*) _quiet_was_on=1; set +x ;; esac; }
_quiet_end()   { if [[ "${_quiet_was_on}" == "1" ]]; then set -x; fi; }

# _central_backend_target <namespace> <service> [<stderr-file>] [<route-target-port>]
# Prints one "<address> <port>" line per ready backend of the service, taken
# from the EndpointSlices the endpoint controller maintains for it. When a
# Route target port is given, the port is the one OpenShift resolves for it.
# Exit status: 0 with output for a ready backend; 0 with no output when the
# EndpointSlices were read and list no ready backend; 2 when the read fails;
# 3 when the read returns a body that cannot be parsed. The two error states
# stay distinct from "no ready backend" so a caller cannot record a read
# failure as a definite negative.
_central_backend_target() {
    # BASH-3: typeset at declaration with an initial value, never the
    # non-POSIX `local` builtin.
    typeset _slice_json='' _backend_target=''
    # Third argument: where oc's own reason for a failed read is appended.
    # Discarding it left the caller's recorded "the EndpointSlice read
    # failed" state without a cause; the default keeps other callers quiet.
    typeset _errfile="${3:-/dev/null}"
    # Fourth argument: the Route's spec.port.targetPort. OpenShift resolves a
    # string target port by Service port name and a numeric one by number, so
    # the EndpointSlice port has to be chosen with that value; the previous
    # form read an annotation that a Route does not carry and then sorted the
    # remaining ports, which picked whichever port happened to sort first.
    typeset _rt_port="${4:-}"
    typeset _oc_rc=0
    typeset _cb_was_on=0; case $- in *x*) _cb_was_on=1; set +x;; esac
    _slice_json="$(oc get endpointslices -n "$1" \
      -l "kubernetes.io/service-name=$2" -o json 2>"${_errfile}")" || _oc_rc=$?
    if (( _oc_rc != 0 )); then if (( _cb_was_on )); then set -x; fi; return 2; fi
    # _errfile is temporary, not artifact; raw error text never leaves as artifact
    if [[ -s "${_errfile}" ]]; then
        printf 'EndpointSlice query failed: %s\n' "$(head -c 200 "${_errfile}")" >&2
    fi
    _backend_target="$(printf '%s\n' "${_slice_json}" | \
      python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(3)

routeTargetPort = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
candidates = []
for item in data.get("items", []):
    ports = [p for p in item.get("ports", []) or [] if p.get("port")]
    if not ports:
        continue
    # PRRT_kwDOBHvUUM65MrkM: the Route target port decides the EndpointSlice
    # port. A string target port is a Service port name, a numeric one is a
    # port number.
    if routeTargetPort:
        if routeTargetPort.isdigit():
            matched = [p for p in ports if str(p.get("port")) == routeTargetPort]
        else:
            matched = [p for p in ports if str(p.get("name")) == routeTargetPort]
        if matched:
            ports = matched
    if len(ports) > 1:
        # Single-port service has one entry; prefer an explicitly named https
        # port when several remain.
        ports.sort(key=lambda p: 0 if p.get("name") == "https" else 1)
    for endpoint in item.get("endpoints", []) or []:
        if (endpoint.get("conditions") or {}).get("ready") is False:
            continue
        for _addr in endpoint.get("addresses") or []:
            pair = "%s %s" % (_addr, ports[0]["port"])
            if pair not in candidates:
                candidates.append(pair)
# PRRT_kwDOBHvUUM65RJoI: every ready backend is a candidate, so a Pod that
# terminates between this read and the connection does not remove the only
# address the download could use.
print("\n".join(candidates))
sys.exit(0)
' "${_rt_port}")" || { if (( _cb_was_on )); then set -x; fi; return 3; }
    printf '%s\n' "${_backend_target}"
    if (( _cb_was_on )); then set -x; fi
}

# ─── ACS Diagnostic Collection ──────────────────────────────────────────────
# Wrapped in a function so early returns (when ACS is not available) do not
# prevent the OLM evidence capture section from running.  This is critical
# because OLM evidence is most valuable when the operator fails to install.

# collect_acs_diagnostics - downloads ACS/StackRox diagnostic bundle
# via the Central API. Skips silently if ACS is not installed.
collect_acs_diagnostics() {
    mkdir -p "${ARTIFACT_DIR}/acs-must-gather"
    BUNDLE_STATUS="not-attempted"

    # Verify ACS is installed (operator namespace)
    ACS_CSV=$(oc get csv -n "${ACS_NAMESPACE}" \
      -l "operators.coreos.com/rhacs-operator.${ACS_NAMESPACE}=" \
      -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "${ACS_CSV}" ]]; then
        echo "WARNING: No ACS CSV found in namespace ${ACS_NAMESPACE} - skipping diagnostic collection."
        echo "SKIPPED: No ACS CSV found" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-csv"
        return 0
    fi

    # The Central workload (route, secret, diagnostic bundle) runs in the
    # namespace named by the Central CR - NOT the operator namespace
    # (ACS_NAMESPACE). Discover it from the CR; without a CR there is no
    # Central to gather from. (INTEROP-9647 D9: this step was previously
    # dead on every stanza - route/secret were queried in the operator
    # namespace and always came back empty.)
    WORKLOAD_NS=$(oc get central -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    if [[ -z "${WORKLOAD_NS}" ]]; then
        echo "WARNING: No Central CR found - cannot determine the ACS workload namespace."
        echo "SKIPPED: No Central CR" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-central-cr"
        return 0
    fi
    echo "ACS workload namespace (from Central CR): ${WORKLOAD_NS}; operator namespace: ${ACS_NAMESPACE}"

    # Get Central route (workload namespace)
    CENTRAL_HOST=$(oc get route central -n "${WORKLOAD_NS}" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)

    if [[ -z "${CENTRAL_HOST}" ]]; then
        echo "WARNING: Central route not found in ${WORKLOAD_NS} - skipping."
        echo "SKIPPED: No Central route" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-route"
        return 0
    fi

    # Retrieve admin password (workload namespace)
    # BASH-7.3: xtrace prints assignment values, so the password read and
    # its emptiness test run with tracing suspended; tracing resumes at once.
    set +x
    ADMIN_PW=$(oc get secret central-htpasswd -n "${WORKLOAD_NS}" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    _adminPwMissing=0
    [[ -n "${ADMIN_PW}" ]] || _adminPwMissing=1
    set -x

    if (( _adminPwMissing )); then
        echo "WARNING: Cannot retrieve Central admin password - skipping."
        echo "SKIPPED: No admin credentials" > "${ARTIFACT_DIR}/acs-must-gather/SKIPPED"
        BUNDLE_STATUS="skipped:no-credentials"
        return 0
    fi

    # Download diagnostic bundle via Central API
    # (same endpoint roxctl central debug download-diagnostics uses)
    echo "Downloading ACS diagnostic bundle..."

    # TLS posture (INTEROP-9647): the `central` route is created with
    # termination: passthrough (RHACS operator chart, 01-central-15-exposure),
    # so the router does not terminate TLS and the client sees Central's own
    # serving certificate from the `central-tls` secret (ca.pem/cert.pem/
    # key.pem) in the Central namespace. Two plausible CAs are both wrong
    # here: the API-server CA at the serviceaccount mount verifies the kube
    # API, not the route (HTTP 000 in rehearsal build 2116737836412571648),
    # and openshift-config-managed/default-ingress-cert is the ROUTER CA,
    # which only applies when the router terminates (edge/reencrypt) and can
    # never verify a passthrough route. Verify against Central's own CA, and
    # exchange the admin password only after that verification succeeds.
    # Initialize retry-path variables so the download retry branch works when
    # the direct TLS preflight succeeded and no backend was selected.
    typeset _central_svc="" _central_route_tp="" _central_svc_dns="" _central_connect_to="" _central_backend="" _central_addr="" _central_port=""
    typeset -i _central_backend_rc=0 _central_direct_rc=0
    TLS_MODE="unverified"
    CURL_TLS_OPTS=""
    CENTRAL_URL_HOST="${CENTRAL_HOST}"
    CENTRAL_CA_FILE="${ARTIFACT_DIR}/acs-must-gather/central-ca.pem"
    TLS_PREFLIGHT_ERR="${ARTIFACT_DIR}/acs-must-gather/tls-preflight.err"
    CENTRAL_CA="$(oc get secret central-tls -n "${WORKLOAD_NS}" \
      -o jsonpath='{.data.ca\.pem}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -n "${CENTRAL_CA}" ]]; then
        printf '%s\n' "${CENTRAL_CA}" > "${CENTRAL_CA_FILE}"
        # Credential-free handshake check against the same endpoint the download
        # uses: curl exit 0 means the served certificate chained to Central's CA
        # (an unauthenticated 401 is still a verified handshake); non-zero means
        # CA or hostname mismatch - no credential is involved either way.
        # -sS keeps successful output silent while surfacing preflight errors
        # in tls-preflight.err (with -s alone a failing preflight left the file
        # the warning points at empty).
        if curl -sS -o /dev/null --cacert "${CENTRAL_CA_FILE}" \
              --connect-timeout 10 --max-time 30 -w '' \
              "https://${CENTRAL_HOST}/v1/debug/diagnostics" 2>"${TLS_PREFLIGHT_ERR}"; then
            TLS_MODE="verified"
            CURL_TLS_OPTS="--cacert ${CENTRAL_CA_FILE}"
        else
            # A passthrough route serving Central's generated certificate can
            # have a route host outside the certificate's service DNS names:
            # the direct preflight then fails hostname verification (curl exit
            # 60) even though the CA is correct, and the bundle would be
            # skipped. The service DNS name is the name the generated
            # certificate covers, but it cannot be presented as SNI to the
            # route host: a passthrough router picks the backend by TLS SNI
            # route match, so a ClientHello naming the service DNS name selects
            # no route and never reaches Central. Retry against a ready backend
            # endpoint of the Central service instead: --connect-to redirects
            # only the TCP connection (backend address and container port),
            # while the URL host stays the service DNS name, so SNI and
            # hostname verification continue to use the verified name against
            # Central's own CA. Routes with a custom certificate that includes
            # the route host pass the direct preflight above and never reach
            # this retry.
            # The Route's spec.port.targetPort decides which EndpointSlice
            # port the fallback may use. Both fields come from one query, with
            # tracing off.
            typeset _route_svc_tp=''
            _quiet_begin
            _route_svc_tp="$(oc get route central -n "${WORKLOAD_NS}" \
              -o jsonpath='{.spec.to.name}{"|"}{.spec.port.targetPort}' 2>/dev/null || true)"
            _central_svc="${_route_svc_tp%%|*}"
            typeset _central_route_tp=''
            if [[ "${_route_svc_tp}" == *'|'* ]]; then
                _central_route_tp="${_route_svc_tp#*|}"
            fi
            typeset _central_backend='' _central_addr='' _central_port=''
            typeset _central_svc_dns='' _central_connect_to=''
            typeset -i _central_backend_rc=0 _central_direct_rc=0
            if [[ -n "${_central_svc}" ]]; then
                typeset _backend_errfile
                _backend_errfile=$(mktemp)
                _central_backend="$(
                  _central_backend_target "${WORKLOAD_NS}" "${_central_svc}" \
                    "${_backend_errfile}" "${_central_route_tp}"
                )" || _central_backend_rc=$?
                if [[ -s "${_backend_errfile}" ]]; then
                    printf "EndpointSlice query failed: %s\n" "$(_api_err_class "$(head -c 200 "${_backend_errfile}")")" >&2
                fi
                rm -f "${_backend_errfile}"
            fi
            if [[ "${_central_backend_rc}" -eq 0 &&
                  -n "${_central_svc}" && -n "${_central_backend}" ]]; then
                _central_svc_dns="${_central_svc}.${WORKLOAD_NS}.svc"
                # Every ready backend is tried in turn: a Pod that terminated
                # after the EndpointSlice read leaves one candidate dead while
                # another can still serve the bundle. The sweep is bounded by
                # the candidate count and by a small fixed cap, and each
                # attempt keeps its own short connect/max time, so a stalled
                # backend cannot consume the step.
                typeset -i _central_tries=0 _central_failed_tries=0
                while read -r _central_addr _central_port; do
                    if [[ -z "${_central_addr}" || -z "${_central_port}" ]]; then
                        continue
                    fi
                    if (( _central_tries >= 3 )); then
                        break
                    fi
                    _central_tries=$(( _central_tries + 1 ))
                    if [[ "${_central_addr}" == *:* ]]; then
                        _central_addr="[${_central_addr}]"
                    fi
                    _central_connect_to="${_central_svc_dns}:443:${_central_addr}:${_central_port}"
                    if curl -sS -o /dev/null --cacert "${CENTRAL_CA_FILE}" \
                          --connect-to "${_central_connect_to}" \
                          --connect-timeout 10 --max-time 30 -w '' \
                          "https://${_central_svc_dns}/v1/debug/diagnostics" \
                          2>/dev/null; then
                        TLS_MODE="verified"
                        CURL_TLS_OPTS="--cacert ${CENTRAL_CA_FILE} --connect-to ${_central_connect_to}"
                        CENTRAL_URL_HOST="${_central_svc_dns}"
                        # Log and artifact text name no service host, backend
                        # address or port (INTEROP-9647 log sanitization):
                        # curl's own stderr, which carries the service DNS
                        # name, is discarded and the failure is recorded as its
                        # exit status.
                        echo "TLS verified against Central's own CA through a ready backend endpoint of the route target service, with the certificate's service name as SNI and verified name (route host outside certificate DNS names)"
                        break
                    else
                        _central_direct_rc=$?
                        _central_failed_tries=$(( _central_failed_tries + 1 ))
                        echo "Backend-direct TLS preflight against a ready backend endpoint failed (curl exit ${_central_direct_rc}); trying the next ready backend." >&2
                    fi
                done <<<"${_central_backend}"
                _quiet_end
                if [[ "${TLS_MODE}" != "verified" ]] && (( _central_failed_tries > 0 )); then
                    echo "backend-direct preflight failed on ${_central_failed_tries} ready backend(s): last curl exit ${_central_direct_rc}" >>"${TLS_PREFLIGHT_ERR}"
                fi
            else
                # Record why the retry could not run: a missing route target, a
                # failed or unparseable EndpointSlice read, and a read that
                # shows no ready backend all leave _central_backend empty, and
                # tls-preflight.err would otherwise show only the route-host
                # error. The read states stay apart from the definite negative.
                # Presence only: neither the route target service name nor the
                # ready backend address belongs in an artifact.
                _svc_present="no"
                _backend_present="no"
                if [[ -n "${_central_svc}" ]]; then
                    _svc_present="yes"
                fi
                if [[ -n "${_central_backend}" ]]; then
                    _backend_present="yes"
                fi
                if [[ -z "${_central_svc}" ]]; then
                    _lookup_state="the route target service is absent, so no EndpointSlice lookup ran"
                elif [[ "${_central_backend_rc}" -eq 2 ]]; then
                    _lookup_state="the EndpointSlice read failed, so a ready backend cannot be ruled out"
                elif [[ "${_central_backend_rc}" -eq 3 ]]; then
                    _lookup_state="the EndpointSlice read returned an unparseable body, so a ready backend cannot be ruled out"
                else
                    _lookup_state="the EndpointSlices read cleanly and list no ready backend"
                fi
                echo "Backend-direct fallback not attempted: route target service present=${_svc_present} ready backend present=${_backend_present} (${_lookup_state})." >>"${TLS_PREFLIGHT_ERR}"
            fi
        fi
    else
        echo "central-tls ca.pem not readable in ${WORKLOAD_NS}" > "${TLS_PREFLIGHT_ERR}"
    fi

    if [[ "${TLS_MODE}" != "verified" ]]; then
        # Never send the Central admin password over an unverified channel.
        # Record what the route actually presents so the CA can be established
        # from evidence instead of guessed.
        curl -s -k -v -o /dev/null --connect-timeout 10 --max-time 30 \
          "https://${CENTRAL_HOST}/v1/debug/diagnostics" \
          2>"${ARTIFACT_DIR}/acs-must-gather/tls-presented-chain.txt" || true
        echo "WARNING: Central TLS verification failed (see tls-preflight.err); not sending admin credentials."
        echo "FAILED: tls-unverified" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
        BUNDLE_STATUS="skipped:tls-unverified"
        return 0
    fi

    # Pass credentials via temp file to keep them out of /proc/cmdline
    CURL_CFG=$(mktemp)
    chmod 600 "${CURL_CFG}"
    trap 'rm -f "${CURL_CFG}"' EXIT
    # BASH-7.3: the credential write must not be traced.
    set +x
    printf 'user = "admin:%s"\n' "$(printf '%s' "${ADMIN_PW}" | sed 's/\\/\\\\/g; s/"/\\"/g')" > "${CURL_CFG}"
    set -x

    # shellcheck disable=SC2086
    # Backend download with bounded retry: if the selected backend terminates
    # after preflight, the download fails. Refresh the candidate list and
    # retry up to three times before givng up, consistent with the existing
    # EndpointSlice retry patterns in this file.
    _quiet_begin
    HTTP_CODE=""
    typeset -i _dl_attempt=0 _dl_max=3
    while (( _dl_attempt < _dl_max )); do
        _dl_attempt=$((_dl_attempt + 1))
        HTTP_CODE=$(curl -s ${CURL_TLS_OPTS} --connect-timeout 10 --max-time 120 -K "${CURL_CFG}" -w '%{http_code}' \
          "https://${CENTRAL_URL_HOST}/v1/debug/diagnostics" \
          -o "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" 2>&1) || {
            echo "WARNING: curl attempt ${_dl_attempt}/${_dl_max} failed to connect to Central." >&2
            HTTP_CODE="000"
        }
        if [[ "${HTTP_CODE}" == "200" ]] && [[ -s "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" ]]; then
            break
        fi
        # On transport failure or non-200, remove any partial file so a
        # truncated ZIP is never treated as publishable.
        if [[ "${HTTP_CODE}" != "200" ]]; then
            rm -f "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip"
        fi
        if (( _dl_attempt < _dl_max )); then
            echo "Retrying diagnostic bundle download (attempt $((_dl_attempt + 1))/${_dl_max}) after refreshing backend candidates..." >&2
            # Refresh backend candidates before retrying, so a newly-ready
            # endpoint can be selected after the previous one terminated.
            if [[ -n "${_central_svc}" ]]; then
                typeset _retry_backend="" _retry_rc=0 _retry_err
                _retry_err=$(mktemp)
                _retry_backend="$(_central_backend_target "${WORKLOAD_NS}" "${_central_svc}" "${_retry_err}" "${_central_route_tp}")" || _retry_rc=$?
                rm -f "${_retry_err}"
                if (( _retry_rc == 0 )) && [[ -n "${_retry_backend}" ]]; then
                    # Update TLS connect-to if a backend-specific override is in use
                    if [[ "${CURL_TLS_OPTS}" == *"--connect-to"* ]]; then
                        typeset _retry_addr="" _retry_port=""
                        read -r _retry_addr _retry_port <<< "$(head -n1 <<< "${_retry_backend}")"
                        if [[ -n "${_retry_addr}" && -n "${_retry_port}" ]]; then
                            if [[ "${_retry_addr}" == *:* ]]; then _retry_addr="[${_retry_addr}]"; fi
                            typeset _retry_svc_dns="${_central_svc}.${WORKLOAD_NS}.svc"
                            typeset _retry_connect="${_retry_svc_dns}:443:${_retry_addr}:${_retry_port}"
                            CURL_TLS_OPTS="--cacert ${CENTRAL_CA_FILE} --connect-to ${_retry_connect}"
                            CENTRAL_URL_HOST="${_retry_svc_dns}"
                        fi
                    fi
                fi
            fi
            sleep 2 || true
        fi
    done
    _quiet_end
    # Transport failures after retries still need the FAILED marker that the
    # single-shot path created in its curl fallback. Remove any partial
    # file from a timed-out curl so it is never treated as publishable.
    if [[ "${HTTP_CODE}" == "000" ]]; then
        rm -f "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip"
        echo "WARNING: curl failed to connect to Central after ${_dl_max} attempts." >&2
        echo "FAILED: curl transport error" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
        BUNDLE_STATUS="failed:transport"
    fi
    if [[ "${HTTP_CODE}" == "200" ]] && \
       [[ -s "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip" ]]; then
        echo "ACS diagnostic bundle downloaded (HTTP ${HTTP_CODE})."
        BUNDLE_STATUS="downloaded"
        cd "${ARTIFACT_DIR}/acs-must-gather"
        unzip -qo acs-diagnostic-bundle.zip -d diagnostic-bundle 2>/dev/null || true
    elif [[ "${HTTP_CODE}" != "000" ]]; then
        rm -f "${ARTIFACT_DIR}/acs-must-gather/acs-diagnostic-bundle.zip"
        echo "WARNING: Diagnostic download failed (HTTP ${HTTP_CODE})."
        BUNDLE_STATUS="failed:http-${HTTP_CODE}"
        echo "FAILED: HTTP ${HTTP_CODE}" > "${ARTIFACT_DIR}/acs-must-gather/FAILED"
    fi

    # Clean up credentials file immediately - the EXIT trap only fires at
    # script end, so remove it here to avoid the password persisting through
    # the OLM evidence capture section.
    rm -f "${CURL_CFG}"
}

# PRRT_kwDOBHvUUM65ui2E: the live acquisition below reads the cluster, so it
# runs from a function that fixture mode skips. self_test and the classification
# helpers it needs are defined further down, which is where the dispatch lives.
run_live_acquisition() {

collect_acs_diagnostics || true

# ─── OLM Evidence Capture (INTEROP-9525) ────────────────────────────────────
# Captures OLM lifecycle state to diagnose why Central CR creation fails
# on OCP 5.0/5.1. Runs with set +e so every command executes even when
# preceding ones fail - capturing absence IS evidence; errexit stays off for the remainder by design.
#
# Each resource is captured with targeted field extraction (not full -o yaml
# or -o json dumps) to avoid leaking sensitive fields such as registry
# credentials, tokens, passwords, or secret refs in operator specs.
#
# Capture contract (docs/design/acs-deploy-evidence.md in the
# opp-interop-testing workspace is the durable authority). Scope: the
# numbered OLM lifecycle captures, steps [1/10] through [10/10].
#   * Every such query is classified three ways: present | absent |
#     probe_error:<rc>, so a query failure is never rendered as absence.
#   * The storage-axis and image captures (11-placementdecisions and 12
#     through 17) are NOT classified: they end in `2>&1 || true`, so a
#     failed oc query leaves that artifact's own parser error (a JSON
#     traceback, not a probe_error marker) and the probe-sanity assertion
#     does not flag it. Read those artifacts as advisory only.
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
#   20: cross-artifact agreement assertion failed (captures disagree)
#   21: evidence probe sanity assertion failed (a required artifact is
#        missing or unparseable)
#        (when several assertions fail, the highest code is reported)
#   22: removal-predicate fixture self-test failed (self-test mode only)

set +e

EVIDENCE_DIR="${ARTIFACT_DIR}/olm-evidence"
mkdir -p "${EVIDENCE_DIR}"

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=== OLM Evidence Capture ===" > "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Timestamp: ${TIMESTAMP}" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "OCP Version: $(oc version -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("openshiftVersion","unknown"))' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"
echo "Cluster ID: $(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo 'unknown')" >> "${EVIDENCE_DIR}/00-capture-metadata.txt"

echo "[${TIMESTAMP}] Starting OLM evidence capture..."

# 1. OperatorPolicy: capture name, spec (subscription target + channel),
#    and status.conditions. The spec is required by the removal predicate
#    (adopt-vs-duplicate and channel comparison); conditions alone cannot
#    distinguish "CRD absent" from "zero objects", so the CRD is probed
#    first and an explicit CRD_ABSENT marker is written when missing.
#    The OperatorPolicy this predicate needs is ACM's (policy.open-cluster-
#    management.io/v1beta1, spec.subscription): only an ACM OperatorPolicy
#    re-creates a Subscription after removal, which is what adopt-vs-duplicate
#    is about. No CRD in group operator.management.openshift.io is registered
#    by OCP or by OLMv1 (operator-controller ships ClusterExtension, not
#    OperatorPolicy), so probing that name could only ever report a false
#    absence. Both the CRD probe and the capture use ACM's fully-qualified
#    name: with more than one OperatorPolicy group registered, the bare plural
#    resolves to whichever discovery orders first and would silently capture
#    the wrong objects (the same trap the Subscription capture below documents).
echo "[1/10] OperatorPolicy..."
# Three-way CRD guard (capture contract): the CRD exists → capture;
# lookup fails NotFound → CRD_ABSENT; fails for any other reason →
# probe_error: a permission or API error must never render as absence.
set +x
OP_CRD_OUTPUT=$(oc get crd operatorpolicies.policy.open-cluster-management.io 2>&1)
OP_CRD_RC=$?
set -x
if [[ ${OP_CRD_RC} -eq 0 ]]; then
  oc get operatorpolicies.policy.open-cluster-management.io -A -o json 2>/dev/null | \
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
  set +x
  if oc_notfound "${OP_CRD_RC}" "${OP_CRD_OUTPUT}"; then
    echo "CRD_ABSENT: operatorpolicies.policy.open-cluster-management.io not registered on this cluster" > "${EVIDENCE_DIR}/01-operatorpolicy.json"
  else
    echo "probe_error: operatorpolicy CRD lookup failed (rc=${OP_CRD_RC} token=$(_api_err_class "${OP_CRD_OUTPUT}"))" > "${EVIDENCE_DIR}/01-operatorpolicy.json"
  fi
  set -x
fi

# 2. CatalogSource - capture name, status.connectionState, spec.image
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

# 3. Subscription: capture name, spec, status.currentCSV/state, and
#    status.conditions (the classification table keys on conditions).
#    Fully-qualified resource type: with ACM installed, the bare
#    `subscription` resolves to ACM's subscriptions.apps.open-cluster-
#    management.io CRD and silently captures the wrong objects.
#    spec.source and spec.sourceNamespace are captured because step [8/10]
#    selects the PackageManifest from the catalog this subscription uses.
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
        # metadata.uid names the object, not its state: a Subscription deleted
        # and recreated under the same name and namespace keeps the name,
        # namespace and generation but gets a new uid.
        "uid": i["metadata"].get("uid"),
        "apiVersion": i.get("apiVersion"),
        "currentCSV": i.get("status", {}).get("currentCSV"),
        "state": i.get("status", {}).get("state"),
        "installPlanRef": (i.get("status", {}).get("installPlanRef") or {}).get("name"),
        "conditions": i.get("status", {}).get("conditions"),
        "channel": i.get("spec", {}).get("channel"),
        "source": i.get("spec", {}).get("source"),
        "sourceNamespace": i.get("spec", {}).get("sourceNamespace"),
        "generation": i.get("metadata", {}).get("generation")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/03-subscription.json" 2>&1 || \
  echo "probe_error: subscription query failed" > "${EVIDENCE_DIR}/03-subscription.json"

# An initial capture failure is a fact about this run and must survive the
# refresh below, which replaces 03-subscription.json: the status is read here,
# where the failure happens, and reported by run_assertions even when the later
# re-read succeeds. A valid empty list is a successful capture, so only the
# failure marker sets it.
if grep -qE '^(probe_error:|QUERY FAILED)' "${EVIDENCE_DIR}/03-subscription.json" 2>/dev/null; then
  _sub_initial_failed=true
  printf '%s\n' "probe_error: initial subscription capture failed" \
    > "${EVIDENCE_DIR}/03-subscription.initial-failed"
fi

# 4. InstallPlan - capture name, status.phase, status.conditions
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

# 5. CSV - capture name, status.phase, status.reason, status.message
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
        "message": i.get("status", {}).get("message"),
        "generation": i.get("metadata", {}).get("generation")
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/05-csv.json" 2>&1 || \
  echo "probe_error: csv query failed" > "${EVIDENCE_DIR}/05-csv.json"

# 6. CRD Established condition for Central
#    Stdout and stderr are captured separately throughout the capture
#    section: the parser reads stdout only (a client-side warning or
#    deprecation notice on stderr must not corrupt the JSON it parses, which
#    would read as a parse failure and fail the probe-sanity assertion on a
#    query that succeeded), and the classification below reads the error
#    text from stderr.
echo "[6/10] Central CRD..."
CRD_TMP="$(mktemp)"
CRD_ERR_TMP="$(mktemp)"
set +x
oc get crd centrals.platform.stackrox.io -o json > "${CRD_TMP}" 2> "${CRD_ERR_TMP}"
CRD_RC=$?
CRD_ERR="$(cat "${CRD_ERR_TMP}")"
set -x
rm -f "${CRD_ERR_TMP}"
if [[ ${CRD_RC} -eq 0 ]]; then
  python3 -c '
import json, sys
data = json.load(sys.stdin)
conditions = data.get("status", {}).get("conditions", [])
print(json.dumps({
    "name": data["metadata"]["name"],
    "conditions": conditions
}, indent=2))
' < "${CRD_TMP}" > "${EVIDENCE_DIR}/06-central-crd.json" 2>&1 || \
    echo "probe_error: central crd parse failed" > "${EVIDENCE_DIR}/06-central-crd.json"
else
  set +x
  if oc_notfound "${CRD_RC}" "${CRD_ERR}"; then
    echo "CRD centrals.platform.stackrox.io NOT FOUND" > "${EVIDENCE_DIR}/06-central-crd.json"
  else
    echo "probe_error: central crd query failed (rc=${CRD_RC} token=$(_api_err_class "${CRD_ERR}"))" > "${EVIDENCE_DIR}/06-central-crd.json"
  fi
  set -x
fi
rm -f "${CRD_TMP}"

# 7. Central CR: capture name, namespace, spec.name, full status, and the
#    Available condition explicitly (the acceptance verdict keys on it).
echo "[7/10] Central CR..."
# Stdout to the parser, stderr to the classifier (see [6/10]).
CR_TMP="$(mktemp)"
CR_ERR_TMP="$(mktemp)"
set +x
oc get centrals.platform.stackrox.io -A -o json > "${CR_TMP}" 2> "${CR_ERR_TMP}"
CR_RC=$?
CR_ERR="$(cat "${CR_ERR_TMP}")"
set -x
rm -f "${CR_ERR_TMP}"
if [[ ${CR_RC} -eq 0 ]]; then
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
' < "${CR_TMP}" > "${EVIDENCE_DIR}/07-central-cr.json" 2>&1 || \
    echo "probe_error: central cr parse failed" > "${EVIDENCE_DIR}/07-central-cr.json"
else
  set +x
  if oc_notfound "${CR_RC}" "${CR_ERR}"; then
    echo "No Central CR found (CRD may not exist)" > "${EVIDENCE_DIR}/07-central-cr.json"
  elif grep -qi "doesn't have a resource type" <<< "${CR_ERR}"; then
    echo "CRD_ABSENT: centrals.platform.stackrox.io not registered on this cluster (successful query, resource type absent)" > "${EVIDENCE_DIR}/07-central-cr.json"
  else
    echo "probe_error: central cr query failed (rc=${CR_RC} token=$(_api_err_class "${CR_ERR}"))" > "${EVIDENCE_DIR}/07-central-cr.json"
  fi
  set -x
fi
rm -f "${CR_TMP}"

# 7b. SecuredCluster CR: same three-way classification as Central; the
#     SecuredCluster gap is tracked separately (see INTEROP-9525 child) and
#     its presence/phase must be observable from the evidence bundle.
echo "[7b/10] SecuredCluster CR..."
# Stdout to the parser, stderr to the classifier (see [6/10]).
SC_TMP="$(mktemp)"
SC_ERR_TMP="$(mktemp)"
set +x
oc get securedclusters.platform.stackrox.io -A -o json > "${SC_TMP}" 2> "${SC_ERR_TMP}"
SC_RC=$?
SC_ERR="$(cat "${SC_ERR_TMP}")"
set -x
rm -f "${SC_ERR_TMP}"
if [[ ${SC_RC} -eq 0 ]]; then
  python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "status": i.get("status"),
    })
print(json.dumps(result, indent=2))
' < "${SC_TMP}" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json" 2>&1 || \
    echo "probe_error: securedcluster parse failed" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
else
  set +x
  if oc_notfound "${SC_RC}" "${SC_ERR}"; then
    echo "No SecuredCluster CR found (CRD may not exist)" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
  elif grep -qi "doesn't have a resource type" <<< "${SC_ERR}"; then
    echo "CRD_ABSENT: securedclusters.platform.stackrox.io not registered on this cluster (successful query, resource type absent)" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
  else
    echo "probe_error: securedcluster cr query failed (rc=${SC_RC} token=$(_api_err_class "${SC_ERR}"))" > "${EVIDENCE_DIR}/07b-securedcluster-cr.json"
  fi
  set -x
fi
rm -f "${SC_TMP}"

# 8. PackageManifest for rhacs-operator: three-way classify (present |
#    absent | probe_error); both files are ALWAYS written. The selection is
#    scoped to the catalog the subscription actually uses: with the package
#    offered by more than one catalog, `oc get packagemanifest
#    rhacs-operator` returns whichever one the server lists first, so the
#    artifact could describe a catalog the subscription does not subscribe
#    to and the catalog-binding precondition then fails on evidence that
#    never looked at the right catalog. The previous
#    --selector=catalog=redhat-operators form false-negatived on clusters
#    where the operator installs fine, and the "not in catalog" conclusion
#    was read from that broken probe; the catalog is now derived from the
#    subscription itself (step [3/10]) instead of being hardcoded.
#    One list query over all namespaces feeds both artifacts, so the
#    per-package capture and the inventory cannot disagree about what the
#    cluster offered, and the inventory records each package's catalog for
#    the agreement assertion below.
echo "[8/10] PackageManifest..."
# The inventory is the largest object captured here and its parser must see
# JSON only, so stdout goes straight to a file and stderr to the classifier
# (see [6/10]).
PM_LIST_TMP="$(mktemp)"
PM_LIST_ERR_TMP="$(mktemp)"
set +x
oc get packagemanifest -A -o json > "${PM_LIST_TMP}" 2> "${PM_LIST_ERR_TMP}"
PM_LIST_RC=$?
PM_LIST_ERR="$(cat "${PM_LIST_ERR_TMP}")"
set -x
rm -f "${PM_LIST_ERR_TMP}"
if [[ ${PM_LIST_RC} -eq 0 ]]; then
  PM_PARSE_RC=0
  python3 - "${EVIDENCE_DIR}" "${PM_LIST_TMP}" <<'PYEOF' || PM_PARSE_RC=$?
import json, sys
from pathlib import Path

ev = Path(sys.argv[1])
items = json.loads(Path(sys.argv[2]).read_text()).get("items", [])

rows = []
for i in items:
    meta = i.get("metadata") or {}
    status = i.get("status") or {}
    name = meta.get("name")
    if not name:
        continue
    rows.append({
        "name": name,
        "catalog": status.get("catalogSource") or "",
        "catalog_ns": (status.get("catalogSourceNamespace")
                       or meta.get("namespace") or ""),
        "channels": [
            {"name": ch.get("name"), "currentCSV": ch.get("currentCSV")}
            for ch in status.get("channels") or []
        ],
    })
rows.sort(key=lambda r: (r["name"], r["catalog"], r["catalog_ns"]))

# Full inventory, always written: one line per PackageManifest with the
# catalog that provides it. Without the catalog column a same-named package
# in another catalog is indistinguishable from the subscribed one.
(ev / "08-all-packagemanifests.txt").write_text(
    "# name\tcatalog\tcatalog-namespace"
    " (every PackageManifest the cluster lists)\n"
    + "".join("%s\t%s\t%s\n" % (r["name"], r["catalog"], r["catalog_ns"])
              for r in rows)
)

# The subscription's own catalog, from the step [3/10] capture.
sub_source = sub_source_ns = None
try:
    subs = json.loads((ev / "03-subscription.json").read_text())
    matches = [s for s in subs if s.get("name") == "rhacs-operator"]
    if len(matches) == 1:
        sub_source = matches[0].get("source")
        sub_source_ns = matches[0].get("sourceNamespace")
except Exception:
    pass

candidates = [r for r in rows if r["name"] == "rhacs-operator"]
out = ev / "08-packagemanifest-rhacs.json"


def key(r):
    return "%s/%s" % (r["catalog"] or "<none>", r["catalog_ns"] or "<none>")


if sub_source:
    selected = [r for r in candidates
                if r["catalog"] == sub_source
                and (not sub_source_ns
                     or r["catalog_ns"] == sub_source_ns)]
    scope = "catalog %s%s" % (
        sub_source,
        " in namespace %s" % sub_source_ns if sub_source_ns else "")
elif len(candidates) <= 1:
    # No subscription source to filter on, but at most one catalog offers
    # the package, so there is nothing to disambiguate: select the single
    # match, or report the absence.
    selected = candidates
    scope = "any catalog (the subscription capture names no source)"
else:
    # No subscription captured (or none named rhacs-operator) and more than
    # one catalog offers the package: nothing attributes a catalog, so no
    # single PackageManifest is claimed. Not an absence: the package exists.
    selected = []
    out.write_text(
        "UNATTRIBUTED: %d PackageManifests named rhacs-operator (%s) and the "
        "subscription capture names no source to select one; the catalog "
        "binding is unknown, not absent (successful query)\n"
        % (len(candidates), ", ".join(key(r) for r in candidates)))
    sys.exit(0)

others = [r for r in candidates if r not in selected]
if not selected:
    out.write_text(
        "ABSENT: no PackageManifest named rhacs-operator in %s "
        "(successful query)%s\n"
        % (scope,
           "; present in other catalogs: %s" % ", ".join(key(r) for r in others)
           if others else ""))
else:
    pm = selected[0]
    out.write_text(json.dumps({
        "name": pm["name"],
        "catalogSource": pm["catalog"] or None,
        "catalogSourceNamespace": pm["catalog_ns"] or None,
        "channels": pm["channels"],
        "selection": {
            "mode": ("subscription-catalog" if sub_source
                     else "single-match"),
            "subscriptionSource": sub_source,
            "subscriptionSourceNamespace": sub_source_ns,
            "candidates": [key(r) for r in candidates],
        },
    }, indent=2) + "\n")
PYEOF
  if [[ ${PM_PARSE_RC} -ne 0 ]]; then
    echo "probe_error: packagemanifest inventory parse failed" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
    echo "probe_error: packagemanifest inventory parse failed" > "${EVIDENCE_DIR}/08-all-packagemanifests.txt"
  fi
else
  # One query drives both artifacts, so both take the same classification.
  set +x
  if oc_notfound "${PM_LIST_RC}" "${PM_LIST_ERR}" || \
     grep -qi "doesn't have a resource type" <<< "${PM_LIST_ERR}"; then
    echo "CRD_ABSENT: packagemanifests.packages.operators.coreos.com not registered on this cluster (successful query, resource type absent)" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
    echo "CRD_ABSENT: packagemanifests.packages.operators.coreos.com not registered on this cluster (successful query, resource type absent)" > "${EVIDENCE_DIR}/08-all-packagemanifests.txt"
  else
    echo "probe_error: packagemanifest list query failed (rc=${PM_LIST_RC} token=$(_api_err_class "${PM_LIST_ERR}"))" > "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json"
    echo "probe_error: packagemanifest list query failed (rc=${PM_LIST_RC} token=$(_api_err_class "${PM_LIST_ERR}"))" > "${EVIDENCE_DIR}/08-all-packagemanifests.txt"
  fi
  set -x
fi
rm -f "${PM_LIST_TMP}"

# 9/10. ACM policies: capture name, status.conditions, and the compliance
#      verdicts (status.compliant, status.status[]). Conditions alone are
#      always null on these objects; the compliance verdict is the field
#      that answers "was the policy reconciled".
#      Both captures use the fully-qualified resource type, matching their
#      CRD probes: the bare `policy` kind is also registered by other API
#      groups (for example Kyverno's policies.kyverno.io), and the same
#      bare-kind collision is what made the Subscription capture collect
#      ACM objects instead of OLM's. A qualified type can only resolve to
#      the CRD probed above, so a capture failure means a real query
#      failure, not the wrong resource type.
echo "[9/10] ACM policies..."
# Three-way CRD guard (capture contract): exists → capture; NotFound →
# CRD_ABSENT; any other failure → probe_error (never render as absence).
set +x
POLICY_CRD_OUTPUT=$(oc get crd policies.policy.open-cluster-management.io 2>&1)
POLICY_CRD_RC=$?
set -x
if [[ ${POLICY_CRD_RC} -eq 0 ]]; then
  oc get policies.policy.open-cluster-management.io -A -o json 2>/dev/null | \
    python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    status = i.get("status", {})
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "conditions": status.get("conditions"),
        "compliant": status.get("compliant"),
        "status": [
            {"clusterName": s.get("clusterName"), "compliant": s.get("compliant")}
            for s in status.get("status", []) or []
        ]
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/09-policies.json" 2>&1 || \
    echo "probe_error: policy query failed" > "${EVIDENCE_DIR}/09-policies.json"
else
  set +x
  if oc_notfound "${POLICY_CRD_RC}" "${POLICY_CRD_OUTPUT}"; then
    echo "CRD_ABSENT: policies.policy.open-cluster-management.io not registered on this cluster" > "${EVIDENCE_DIR}/09-policies.json"
  else
    echo "probe_error: policy CRD lookup failed (rc=${POLICY_CRD_RC} token=$(_api_err_class "${POLICY_CRD_OUTPUT}"))" > "${EVIDENCE_DIR}/09-policies.json"
  fi
  set -x
fi
set +x
CONFIGPOLICY_CRD_OUTPUT=$(oc get crd configurationpolicies.policy.open-cluster-management.io 2>&1)
CONFIGPOLICY_CRD_RC=$?
set -x
if [[ ${CONFIGPOLICY_CRD_RC} -eq 0 ]]; then
  oc get configurationpolicies.policy.open-cluster-management.io -A -o json 2>/dev/null | \
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
else
  set +x
  if oc_notfound "${CONFIGPOLICY_CRD_RC}" "${CONFIGPOLICY_CRD_OUTPUT}"; then
    echo "CRD_ABSENT: configurationpolicies.policy.open-cluster-management.io not registered on this cluster" > "${EVIDENCE_DIR}/10-configpolicies.json"
  else
    echo "probe_error: configurationpolicy CRD lookup failed (rc=${CONFIGPOLICY_CRD_RC} token=$(_api_err_class "${CONFIGPOLICY_CRD_OUTPUT}"))" > "${EVIDENCE_DIR}/10-configpolicies.json"
  fi
  set -x
fi

# 10. ACM CSV version and governance-policy-addon-controller image ref:
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
        # status.reason distinguishes an OLM copy from the CSV it copies: a
        # copy repeats the version and the images, so a selector that cannot
        # see the reason counts two records for one installation.
        "reason": i.get("status", {}).get("reason"),
        "version": i.get("spec", {}).get("version"),
        "governancePolicyAddonControllerImages": images,
    })
print(json.dumps(result, indent=2))
' > "${EVIDENCE_DIR}/11-acm-csv-addon-controller.json" 2>&1 || \
  echo "probe_error: acm csv query failed" > "${EVIDENCE_DIR}/11-acm-csv-addon-controller.json"
}

if [[ "${ACS_EVIDENCE_SELF_TEST:-0}" == "1" ]]; then
    # Fixture mode runs the classification fixtures only.
    :
else
    run_live_acquisition
fi

# ─── Removal predicate (per-run terms) ──────────────────────────────────────
# Evaluates the per-run facts defined in
# docs/design/acs-deploy-evidence.md §3 and writes them to
# acs-central-status.properties next to the evidence. The two-run
# aggregation is a ticket-level rule, NOT computed here.
write_status_properties() {
  python3 - "$EVIDENCE_DIR" <<'PYEOF'
import json, os, sys
from pathlib import Path

ev = Path(sys.argv[1])

def probe(name):
    """Classify an evidence file without collapsing failure into absence.

    Returns (status, data) with status one of:
      ok           : parsed JSON (data carries it)
      absent       : successful query, resource/type genuinely absent
      query_failed : QUERY FAILED / probe_error marker
      unparseable  : neither of the above and not valid JSON
      missing      : file not written
    A failed query must never read as an empty capture: the report then
    says unknown, not absent."""
    p = ev / name
    try:
        raw = p.read_text()
    except Exception:
        return "missing", None
    if raw.startswith("QUERY FAILED") or raw.startswith("probe_error:"):
        return "query_failed", None
    if (raw.startswith("CRD_ABSENT") or raw.startswith("No ")
            or raw.startswith("ABSENT:")):
        return "absent", None
    try:
        return "ok", json.loads(raw)
    except Exception:
        return "unparseable", None

def as_list(name):
    status, data = probe(name)
    if status == "ok" and isinstance(data, list):
        return status, data
    return status, []

ops_s, ops = as_list("01-operatorpolicy.json")
subs_s, subs = as_list("03-subscription.json")
# A failed refresh is recorded in a shell flag, so it holds even when the
# probe_error write to 03-subscription.json is refused and an earlier
# capture stays readable.
if os.environ.get("ACS_SUB_REFRESH_FAILED") == "true":
    subs_s, subs = "query_failed", []
# The snapshot comparison state travels the same way: same / changed /
# unknown. Anything but same withholds readiness, and a failed re-read makes it
# unknown even when the earlier file was readable.
sub_snapshot = os.environ.get("ACS_SUB_SNAPSHOT", "same")
if os.environ.get("ACS_SUB_REFRESH_FAILED") == "true":
    sub_snapshot = "unknown"
sub_snapshot_term = {"same": "true", "changed": "false"}.get(sub_snapshot, "unknown")
csvs_s, csvs = as_list("05-csv.json")
central_s, central = as_list("07-central-cr.json")
acm_s, acm = as_list("11-acm-csv-addon-controller.json")
pm_s, pm = probe("08-packagemanifest-rhacs.json")
pm_ok = pm_s == "ok" and isinstance(pm, dict)

rhacs_subs = [s for s in subs if s.get("name") == "rhacs-operator"]
sub = rhacs_subs[0] if len(rhacs_subs) == 1 else None
sub_source = sub.get("source") if sub else None
sub_namespace = sub.get("namespace") if sub else None

# Effective catalog source of the subscription: spec.source
# (adopted subscriptions keep theirs); fall back to the catalog of the
# packagemanifest whose channel resolves the subscription's currentCSV.
effective_source = sub_source
if effective_source is None and sub is not None and pm_ok:
    for ch in pm.get("channels") or []:
        if ch.get("currentCSV") and ch.get("currentCSV") == sub.get("currentCSV"):
            effective_source = pm.get("catalogSource")
            break

# CSVs: exclude OLM copies (reason Copied) and bind to the subscription
# namespace: name-only counting accepted same-named packages from
# another catalog.
rhacs_csvs = [
    c for c in csvs
    if c.get("name", "").startswith("rhacs-operator.v")
    and c.get("reason") != "Copied"
    and (sub_namespace is None or c.get("namespace") == sub_namespace)
]

# CSV binding (the installed CSV must be the subscription's resolved version,
# not just any non-copied rhacs-operator.v* CSV): an upgrade-pending cluster
# whose only installed CSV is one release behind the subscription's
# currentCSV read as removal-ready with the upgrade still outstanding. The
# installed CSV must be the CSV the subscription resolves, reported as its
# own term. Kept separate from rhacs_csvs instead of filtering that list, so
# rhacs_csv_count still means "CSVs installed for the package" and the
# exactly-one precondition is not quietly narrowed to "one CSV that happens
# to match" (a lingering second CSV would otherwise go uncounted). The term
# reads unknown only when there is no single rhacs subscription to read; a
# subscription that publishes no currentCSV compares against nothing and
# reads false, so the term is fail-closed and never true without a match.
if sub is None:
    rhacs_csv_matches_subscription = None
else:
    rhacs_csv_matches_subscription = any(
        c.get("name") == sub.get("currentCSV") for c in rhacs_csvs
    )

sub_name = sub.get("name") if sub else None
sub_ns = sub.get("namespace") if sub else None
# PRRT_kwDOBHvUUM65yNGT: select OperatorPolicy by full Subscription identity, no name-only fallback
rhacs_op = [o for o in ops if o.get("name") == "operatorpolicy-rhacs-operator" and o.get("spec", {}).get("subscriptionName") == sub_name and o.get("spec", {}).get("subscriptionNamespace") == sub_ns] if sub_name and sub_ns else []
# Ambiguous match must not pass on list order: require exactly one policy
rhacs_op_count = len(rhacs_op)
rhacs_op_ambiguous = rhacs_op_count > 1
rhacs_op_single = rhacs_op[0] if rhacs_op_count == 1 else None

sub_channel = sub.get("channel") if sub else None
op_spec = (rhacs_op_single.get("spec") or {}) if rhacs_op_single else {}
op_channel = op_spec.get("channel")

# Target binding: the OperatorPolicy must name THIS subscription. A policy
# whose spec.subscription names another subscription re-creates that one on
# removal, so adopt-vs-duplicate does not apply to rhacs-operator and the
# precondition cannot be met. A field the policy leaves unset (None) does not
# constrain, mirroring OLM's defaulting of an omitted target, so only a
# declared and different value fails. With no single rhacs subscription to
# bind to, the binding is unknown, not false.
#
# The no-policy case is separate: with no OperatorPolicy captured there are
# no target fields at all, and reading both as "unset, so does not constrain"
# reported operatorpolicy_targets_subscription=true for a cluster that has no
# policy to do the targeting. A classified query that found no policy means
# nothing targets the subscription (false), while a failed capture means the
# answer is unknown.
op_sub_name = op_spec.get("subscriptionName")
op_sub_namespace = op_spec.get("subscriptionNamespace")
if ops_s not in ("ok", "absent"):
    op_owns_sub = None
elif rhacs_op_ambiguous:
    op_owns_sub = None
elif not rhacs_op:
    op_owns_sub = False
elif sub is None:
    op_owns_sub = None
else:
    if op_sub_name is None or op_sub_namespace is None:
        op_owns_sub = None
    else:
        op_owns_sub = (
            op_sub_name == sub.get("name")
            and op_sub_namespace == (sub.get("namespace") or "")
        )
op_compliant = None
if rhacs_op_single:
    conds = rhacs_op_single.get("conditions") or []
    op_compliant = any(
        c.get("type") == "Compliant" and c.get("status") == "True"
        for c in conds
    )

# Enforcement gate: compliance alone does not make the policy the owner of
# the subscription. An OperatorPolicy with remediationAction: inform reports
# compliance and never re-creates a removed Subscription, and a mustnothave
# policy would work against the object's existence rather than restoring it,
# so neither can satisfy the removal precondition. Only a declared enforcing
# action with a re-creating compliance type counts. An unset field reads
# unknown (fail closed) instead of assuming a default: the captured artifact
# records the policy spec only, and a PlacementBinding can override
# enforcement at a level this step does not capture.
op_remediation = None
op_compliance = None
if rhacs_op_single and ops_s in ("ok", "absent"):
    op_remediation = (
        str(op_spec.get("remediationAction") or "").strip().lower() or None
    )
    op_compliance = (
        str(op_spec.get("complianceType") or "").strip().lower() or None
    )
op_enforcing = None
if op_remediation is not None:
    op_enforcing = op_remediation == "enforce"
op_recreates = None
if op_compliance is not None:
    op_recreates = op_compliance in ("musthave", "mustonlyhave")

# Central presence: unknown (not absent) when the capture failed:
# distinct report values for query-failed vs resource-absent.
if central_s == "ok":
    central_present = bool(central) and len(central) > 0
    central_available = any(
        (c.get("available") or {}).get("status") == "True" for c in central
    ) if central_present else False
elif central_s == "absent":
    central_present = False
    central_available = False
else:
    central_present = None
    central_available = None

acm_version = None
addon_images = []
# The ACM version and the addon controller image describe one build, so both
# are read from one CSV record. Exactly one record supplying both is
# authoritative. When the capture holds no such record, or several that cannot
# be told apart, both values report unknown: mixing a version from one record
# with an image from another attributes the image of one build to another. The
# full capture is retained in 11-acm-csv-addon-controller.json either way.
# OLM copies are excluded the same way the rhacs CSV selector excludes them:
# a copy in another namespace repeating the source version and images would
# otherwise make every record ambiguous and report both values unknown.
_acm_records = [a for a in acm
                if a.get("version") and a.get("governancePolicyAddonControllerImages")
                and a.get("reason") != "Copied"]
if len(_acm_records) == 1:
    acm_version = _acm_records[0]["version"]
    addon_images = _acm_records[0]["governancePolicyAddonControllerImages"] or []
elif len(_acm_records) > 1:
    _acm_succeeded = [a for a in _acm_records if a.get("phase") == "Succeeded"]
    if len(_acm_succeeded) == 1:
        acm_version = _acm_succeeded[0]["version"]
        addon_images = _acm_succeeded[0]["governancePolicyAddonControllerImages"] or []
# Generation is a per-object counter: a Subscription generation and a CSV
# generation are not comparable, so membership is carried by the currentCSV,
# phase, channel and catalog terms below.

# Catalog binding: the packagemanifest that provides the
# package must live in the subscription's effective catalog source. With
# no packagemanifest at all, a CSV's catalog origin is unverifiable:
# fail closed rather than accept it on name alone.
if pm_ok and effective_source is not None:
    csv_catalog_matches_subscription = pm.get("catalogSource") == effective_source
elif pm_s == "absent" and rhacs_csvs:
    csv_catalog_matches_subscription = False
else:
    csv_catalog_matches_subscription = None

# Channel resolution: the catalog term says which catalog the packagemanifest
# lives in, not that the manifest still offers the version the subscription
# resolves. An upgrade-pending cluster keeps the right catalog, so the
# catalog term alone cannot tell a settled install from one the catalog has
# already moved past. The captured manifest must list the subscription's
# currentCSV on one of its channels, reported as its own term so the two
# bindings are independently readable.
sub_currentcsv = sub.get("currentCSV") if sub is not None else None
if pm_ok and sub_currentcsv:
    packagemanifest_resolves_current_csv = any(
        ch.get("currentCSV") == sub_currentcsv
        for ch in pm.get("channels") or []
    )
elif pm_s == "absent" and rhacs_csvs:
    packagemanifest_resolves_current_csv = False
else:
    packagemanifest_resolves_current_csv = None

# The predicate is computable only when every input is definitively
# classified (present or absent); query failures make it unknown.
inputs_classified = (
    all(st in ("ok", "absent")
        for st in (ops_s, subs_s, csvs_s, central_s, acm_s))
    and pm_s in ("ok", "absent")
)

# Per-term values follow the Central presence rule: a query
# failure reads as unknown, never as confirmed absence (false/0).
terms = {
    "central_query": central_s,
    "central_present": (str(central_present).lower()
                        if central_present is not None else "unknown"),
    "central_available": (str(central_available).lower()
                          if central_available is not None else "unknown"),
    "rhacs_subscription_count": (str(len(rhacs_subs))
                                 if subs_s in ("ok", "absent") else "unknown"),
    "rhacs_subscription_channel": sub_channel or "unknown",
    "rhacs_subscription_source": effective_source or "unknown",
    "rhacs_csv_count": (str(len(rhacs_csvs))
                        if csvs_s in ("ok", "absent") else "unknown"),
    "rhacs_csv_name": rhacs_csvs[0]["name"] if rhacs_csvs else "unknown",
    "rhacs_csv_phase": (rhacs_csvs[0].get("phase") or "unknown"
                        if rhacs_csvs else "unknown"),
    "rhacs_csv_matches_subscription": (
        str(rhacs_csv_matches_subscription).lower()
        if rhacs_csv_matches_subscription is not None else "unknown"),
    "csv_catalog_matches_subscription": (
        str(csv_catalog_matches_subscription).lower()
        if csv_catalog_matches_subscription is not None else "unknown"),
    "packagemanifest_resolves_current_csv": (
        str(packagemanifest_resolves_current_csv).lower()
        if packagemanifest_resolves_current_csv is not None else "unknown"),
    "operatorpolicy_present": ("unknown" if rhacs_op_ambiguous else str(bool(rhacs_op)).lower()
                               if ops_s in ("ok", "absent") else "unknown"),
    "operatorpolicy_compliant": ("unknown" if rhacs_op_ambiguous else str(op_compliant).lower()
                                  if op_compliant is not None else "unknown"),
    "operatorpolicy_spec_channel": ("unknown" if rhacs_op_ambiguous else op_channel or "unknown"),
    "operatorpolicy_targets_subscription": (
        "unknown" if rhacs_op_ambiguous else str(op_owns_sub).lower() if op_owns_sub is not None else "unknown"),
    "operatorpolicy_remediation_action": ("unknown" if rhacs_op_ambiguous else op_remediation or "unknown"),
    "operatorpolicy_enforcing": (
        "unknown" if rhacs_op_ambiguous else str(op_enforcing).lower() if op_enforcing is not None else "unknown"),
    "operatorpolicy_compliance_type": ("unknown" if rhacs_op_ambiguous else op_compliance or "unknown"),
    "operatorpolicy_recreates_subscription": (
        "unknown" if rhacs_op_ambiguous else str(op_recreates).lower() if op_recreates is not None else "unknown"),
    "acm_csv_version": acm_version or "unknown",
    "addon_controller_image": (addon_images[0].get("image")
                                if addon_images else "unknown"), # PRRT_kwDOBHvUUM65yNGZ: ACM version and controller image from same CSV
    "predicate_inputs_classified": str(inputs_classified).lower(),
    # Stability across the run: the early capture and the post-capture re-read
    # must describe the same Subscription, or this run did not observe a
    # settled object.
    "rhacs_subscription_unchanged": sub_snapshot_term,
}
# Per-run removal precondition: the OperatorPolicy owns the rhacs
# subscription (its spec.subscription targets that subscription) with a
# matching channel, one non-copied CSV in the subscription namespace that is
# the CSV the subscription resolves and that has reached Succeeded, the
# package resolvable in the subscription's effective catalog source and
# offering the version the subscription resolves, and the policy actually
# enforces a re-creating state (a compliant inform or mustnothave policy
# would not restore the subscription). The two-run aggregation and the
# named-build comparison live in the ticket rule. The phase term mirrors
# deploy-acs, which waits for status.phase Succeeded before it reports the
# operator deployed: a CSV still Installing, Replacing, Failed, or Pending
# leaves the install unsettled even when the CSV is the resolved one.
terms["removal_preconditions_met"] = str(
    inputs_classified
    and rhacs_op_count == 1
    and terms["operatorpolicy_compliant"] == "true"
    and terms["operatorpolicy_targets_subscription"] == "true"
    and terms["operatorpolicy_enforcing"] == "true"
    and terms["operatorpolicy_recreates_subscription"] == "true"
    and terms["rhacs_subscription_count"] == "1"
    and terms["rhacs_csv_count"] == "1"
    and terms["rhacs_csv_matches_subscription"] == "true"
    and terms["rhacs_csv_phase"] == "Succeeded"
    and terms["rhacs_subscription_channel"] != "unknown"
    and terms["rhacs_subscription_channel"] == terms["operatorpolicy_spec_channel"]
    and terms["rhacs_subscription_source"] != "unknown"
    and terms["csv_catalog_matches_subscription"] == "true"
    and terms["packagemanifest_resolves_current_csv"] == "true"
    and terms["rhacs_subscription_unchanged"] == "true"
).lower()

out = ev / "acs-central-status.properties"
with out.open("w") as f:
    f.write("# ACS central/removal-predicate status (per-run terms)\n")
    for k in sorted(terms):
        f.write(f"{k}={terms[k]}\n")
print(f"wrote {out}")
PYEOF
}

# _sub_snapshot_state <early-json> <refreshed-json>: compare the same
# Subscription object (name, namespace) across the two captures and print
# same | changed | unknown. A second Subscription in another namespace is a
# different object, so it is not a change to this one. unknown means the pair
# cannot be compared (unparsable capture, or no rhacs-operator Subscription in
# the early one), which withholds readiness the same way a change does.
_sub_snapshot_state() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys

FIELDS = ("channel", "source", "sourceNamespace", "currentCSV", "generation")


def load(path):
    try:
        data = json.loads(open(path, encoding="utf-8").read())
    except Exception:
        return None
    return data if isinstance(data, list) else None


def records(data):
    return [s for s in data
            if isinstance(s, dict) and s.get("name") == "rhacs-operator"]


early, late = load(sys.argv[1]), load(sys.argv[2])
if early is None or late is None:
    print("unknown")
    sys.exit(0)
early_records = records(early)
if len(early_records) != 1:
    # No single early record to compare against, or an ambiguous one.
    print("unknown")
    sys.exit(0)
early_obj = early_records[0]
identity = (early_obj.get("name"), early_obj.get("namespace"))
same_object = [r for r in records(late)
               if (r.get("name"), r.get("namespace")) == identity]
if not same_object:
    # The object that was captured is gone from the cluster.
    print("changed")
    sys.exit(0)
if len(same_object) > 1:
    print("unknown")
    sys.exit(0)
late_obj = same_object[0]
early_uid, late_uid = early_obj.get("uid"), late_obj.get("uid")
if not early_uid or not late_uid:
    # A capture that does not carry the uid cannot prove the object is the
    # same one, which withholds readiness the same way a change does.
    print("unknown")
elif early_uid != late_uid:
    # Same name and namespace, different object: the original was deleted and
    # a replacement resolved the same CSV.
    print("changed")
else:
    print("changed" if any(early_obj.get(f) != late_obj.get(f) for f in FIELDS)
          else "same")
PYEOF
}

# Refresh Subscription snapshot after the last capture so the removal
# predicate does not evaluate readiness terms against a stale currentCSV
# if OLM advanced it in the window between the early Subscription capture
# and the later CSV/PackageManifest captures. Bounded and classified like
# the initial capture: a failed re-read writes probe_error so relevant
# terms become unknown rather than silently keeping the earlier value.
# xtrace stays in force for this block (BASH-1), and a Subscription response
# can hold literal credentials in spec.config.env, so the response goes to a
# private temporary file and the parser reads that file as its input: neither
# the redirect nor the stdin feed expands the JSON into a traced word.
_sub_refresh_failed=false
_sub_snapshot="same"
if [[ "${ACS_EVIDENCE_SELF_TEST:-0}" != "1" ]]; then
  _sub_refresh_ok=false
  _sub_refresh_raw=$(mktemp)
  _sub_refresh_err=$(mktemp)
  _sub_early=$(mktemp)
  cp "${EVIDENCE_DIR}/03-subscription.json" "${_sub_early}" 2>/dev/null || : > "${_sub_early}"
  _sub_refresh_deadline=$(( $(date +%s) + 120 ))
  typeset -i _sub_refresh_try=0 _sub_refresh_remain=0 _sub_refresh_wait=0 _sub_refresh_sleep=0
  for _sub_refresh_try in 1 2 3; do
    _sub_refresh_remain=$(( _sub_refresh_deadline - $(date +%s) ))
    if (( _sub_refresh_remain <= 5 )); then break; fi
    _sub_refresh_wait=$(( _sub_refresh_remain < 45 ? _sub_refresh_remain : 45 ))
    if timeout "${_sub_refresh_wait}s" oc get subscriptions.operators.coreos.com -A --request-timeout=30s -o json >"${_sub_refresh_raw}" 2>"${_sub_refresh_err}"; then
      _sub_refresh_ok=true
      break
    fi
    if (( _sub_refresh_try < 3 )); then
      _sub_refresh_sleep=$(( _sub_refresh_try * 2 ))
      _sub_refresh_remain=$(( _sub_refresh_deadline - $(date +%s) ))
      (( _sub_refresh_sleep > _sub_refresh_remain )) && _sub_refresh_sleep=${_sub_refresh_remain}
      (( _sub_refresh_sleep > 0 )) && sleep "${_sub_refresh_sleep}"
    fi
  done
  rm -f "${_sub_refresh_err}"
  if [[ "${_sub_refresh_ok}" == "true" ]]; then
    python3 -c '
import json, sys
data = json.load(sys.stdin)
result = []
for i in data.get("items", []):
    result.append({
        "name": i["metadata"]["name"],
        "namespace": i["metadata"].get("namespace", ""),
        "uid": i["metadata"].get("uid"),
        "apiVersion": i.get("apiVersion"),
        "currentCSV": i.get("status", {}).get("currentCSV"),
        "state": i.get("status", {}).get("state"),
        "installPlanRef": (i.get("status", {}).get("installPlanRef") or {}).get("name"),
        "conditions": i.get("status", {}).get("conditions"),
        "channel": i.get("spec", {}).get("channel"),
        "source": i.get("spec", {}).get("source"),
        "sourceNamespace": i.get("spec", {}).get("sourceNamespace"),
        "generation": i.get("metadata", {}).get("generation")
    })
print(json.dumps(result, indent=2))
' < "${_sub_refresh_raw}" > "${EVIDENCE_DIR}/03-subscription.json.tmp" || {
      _sub_refresh_failed=true
      echo "probe_error: subscription query failed" > "${EVIDENCE_DIR}/03-subscription.json"
      echo "probe_error: subscription query failed" > "${EVIDENCE_DIR}/03-subscription.refresh-failed"
      rm -f "${EVIDENCE_DIR}/03-subscription.json.tmp"
    }
    if [[ -f "${EVIDENCE_DIR}/03-subscription.json.tmp" ]]; then
      # A changed object means the install did not settle during this run: the
      # refreshed values are still the ones recorded, but readiness is withheld
      # rather than reporting a state the run never held in one snapshot.
      _sub_snapshot="$(_sub_snapshot_state "${_sub_early}" "${EVIDENCE_DIR}/03-subscription.json.tmp")" || _sub_snapshot="unknown"
      if [[ "${_sub_snapshot}" != "same" ]]; then
        printf '%s\n' "Warning: the rhacs-operator Subscription snapshot state is ${_sub_snapshot}; removal readiness is withheld" >&2
      fi
      if ! mv -f "${EVIDENCE_DIR}/03-subscription.json.tmp" "${EVIDENCE_DIR}/03-subscription.json"; then
        _sub_refresh_failed=true
        echo "probe_error: subscription refresh mv failed" > "${EVIDENCE_DIR}/03-subscription.json"
        echo "probe_error: subscription refresh mv failed" > "${EVIDENCE_DIR}/03-subscription.refresh-failed"
      fi
      rm -f "${EVIDENCE_DIR}/03-subscription.json.tmp"
    fi
  else
    _sub_refresh_failed=true
    echo "probe_error: subscription re-read failed after 3 attempts" > "${EVIDENCE_DIR}/03-subscription.json"
    echo "probe_error: subscription re-read failed after 3 attempts" > "${EVIDENCE_DIR}/03-subscription.refresh-failed"
    _sub_snapshot="unknown"
  fi
  rm -f "${_sub_early}" "${_sub_refresh_raw}"
fi

# PRRT_kwDOBHvUUM65ui2E: fixture mode writes these terms into its own temporary
# evidence directory, so the live call must not run without a captured bundle.
_properties_rc=0
if [[ "${ACS_EVIDENCE_SELF_TEST:-0}" == "1" ]]; then
    :
else
    if ! EVIDENCE_DIR="${EVIDENCE_DIR}" ACS_SUB_REFRESH_FAILED="${_sub_refresh_failed}" ACS_SUB_SNAPSHOT="${_sub_snapshot}" write_status_properties; then
        echo "ASSERTION FAILURE (21): acs-central-status.properties could not be written, so the removal predicate terms are missing from the evidence" >&2
        _properties_rc=21
    fi
fi

# ─── Cross-artifact agreement assertions ────────────────────────────────────
# A query failure must never read as absence, and captures that describe the
# same cluster state must agree. These assertions fail the step (exit 20/21)
# so the disagreement is visible in finished.json: job color is not the
# signal (this step is best_effort). Failure aggregation: the highest
# failure code is reported: a later failing check never overwrites an
# earlier one, and an unexpected python exit is normalized to 21 so it
# cannot masquerade as a disagreement (20).
# Packagemanifest/inventory agreement: a per-package capture and the cluster
# inventory that describe the same package must agree on the package, its
# catalog and that catalog namespace. The evidence directory comes from
# EVIDENCE_DIR; returns 0 (agree), 20 (disagreement), 21 (evidence
# unusable) so the self-test can drive it with fixture files instead of a
# cluster.
assert_packagemanifest_agreement() {
  python3 - "${EVIDENCE_DIR}" <<'PYEOF'
import json, sys
from pathlib import Path

ev = Path(sys.argv[1])
inv_raw = (ev / "08-all-packagemanifests.txt").read_text()
if inv_raw.startswith(("probe_error:", "QUERY FAILED")):
    print("ASSERTION FAILURE (21): 08-all-packagemanifests.txt carries no "
          "inventory: " + inv_raw.splitlines()[0][:160])
    sys.exit(21)
inv = []
if not inv_raw.startswith("CRD_ABSENT"):
    for line in inv_raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 3:
            print("ASSERTION FAILURE (21): malformed inventory line: "
                  + line[:160])
            sys.exit(21)
        inv.append(tuple(parts))

# Catalog the subscription subscribes to (step [3/10] capture).
sub_source = sub_source_ns = None
try:
    subs = json.loads((ev / "03-subscription.json").read_text())
    matches = [s for s in subs if s.get("name") == "rhacs-operator"]
    if len(matches) == 1:
        sub_source = matches[0].get("source")
        sub_source_ns = matches[0].get("sourceNamespace")
except Exception:
    pass


def in_subscribed_catalog(row):
    name, catalog, catalog_ns = row
    if name != "rhacs-operator":
        return False
    if sub_source is None:
        return True  # no known catalog: any listing counts
    return catalog == sub_source and (not sub_source_ns
                                      or catalog_ns == sub_source_ns)


listed_scoped = any(in_subscribed_catalog(r) for r in inv)
listed_anywhere = sorted({"%s/%s" % (c, ns) for n, c, ns in inv
                          if n == "rhacs-operator"})
scoped_label = "%s/%s" % (sub_source or "<unknown>", sub_source_ns or "<any>")

perpkg_raw = (ev / "08-packagemanifest-rhacs.json").read_text()
if perpkg_raw.startswith(("ABSENT:", "CRD_ABSENT")):
    present, selection = False, None
elif perpkg_raw.startswith("UNATTRIBUTED"):
    # The package exists in several catalogs and no subscription attributes
    # one: the capture claims no catalog, so only the listing is checkable.
    present, selection = True, None
elif perpkg_raw.startswith(("probe_error:", "QUERY FAILED")):
    print("ASSERTION FAILURE (21): 08-packagemanifest-rhacs.json carries no "
          "classification: " + perpkg_raw.splitlines()[0][:160])
    sys.exit(21)
else:
    try:
        perpkg = json.loads(perpkg_raw)
        present = isinstance(perpkg, dict) and perpkg.get("name") == "rhacs-operator"
        selection = perpkg if present else None
    except Exception:
        present, selection = None, None
if present is None:
    print("ASSERTION FAILURE (21): 08-packagemanifest-rhacs.json is not a "
          "present|absent classification: " + perpkg_raw.splitlines()[0][:160])
    sys.exit(21)
if present and selection is None and not listed_anywhere:
    print("ASSERTION FAILURE (20): packagemanifest disagreement: the capture "
          "reports an unattributed rhacs-operator PackageManifest but the "
          "inventory lists none")
    sys.exit(20)
# The selected package, catalog and namespace must appear together in the
# inventory. A catalog match alone hides a namespace disagreement, so this
# check is independent of listed_scoped: the subscription-scoped match below
# decides whether the subscription agrees, not whether the tuple exists.
if present and selection is not None and selection.get("catalogSource") is not None:
    # The package name belongs to the identity: a catalog/namespace pair that
    # lists a different package says nothing about where rhacs-operator lives.
    _sel_tuple = ("rhacs-operator", selection.get("catalogSource"),
                  selection.get("catalogSourceNamespace"))
    if _sel_tuple not in set(inv):
        print("ASSERTION FAILURE (20): selected package, catalog and namespace "
              "%s/%s/%s are not listed together in the inventory (listed: %s)"
              % (_sel_tuple[0], _sel_tuple[1], _sel_tuple[2],
                 ", ".join(listed_anywhere) or "none"))
        sys.exit(20)
if present and selection is not None and not listed_scoped:
    print("ASSERTION FAILURE (20): packagemanifest disagreement: the "
          "per-package capture reports rhacs-operator present in %s/%s but "
          "the inventory does not list it in the subscribed catalog %s "
          "(listed: %s)"
          % (selection.get("catalogSource"),
             selection.get("catalogSourceNamespace"), scoped_label,
             ", ".join(listed_anywhere) or "none"))
    sys.exit(20)
if present and selection is not None:
    sel_catalog = selection.get("catalogSource")
    sel_catalog_ns = selection.get("catalogSourceNamespace")
    if sub_source is None:
        # No subscription: the single-catalog acceptance is about the
        # rhacs-operator rows, not every package the catalog lists.
        rhacs_inv = [r for r in inv if r[0] == "rhacs-operator"]
        if len(rhacs_inv) == 1 and sel_catalog == rhacs_inv[0][1] and sel_catalog_ns == rhacs_inv[0][2]:
            pass
        elif sel_catalog != sub_source or (sub_source_ns and sel_catalog_ns != sub_source_ns):
            print("ASSERTION FAILURE (20): packagemanifest disagreement: the "
                  "per-package selection reports catalog %s/%s but the subscription "
                  "subscribes to %s (selection does not match subscribed source)"
                  % (sel_catalog, sel_catalog_ns, scoped_label))
            sys.exit(20)
    elif sel_catalog != sub_source or (sub_source_ns and sel_catalog_ns != sub_source_ns):
        print("ASSERTION FAILURE (20): packagemanifest disagreement: the "
              "per-package selection reports catalog %s/%s but the subscription "
              "subscribes to %s (selection does not match subscribed source)"
              % (sel_catalog, sel_catalog_ns, scoped_label))
        sys.exit(20)
if present is False and listed_scoped:
    print("ASSERTION FAILURE (20): packagemanifest disagreement: the "
          "per-package capture reports rhacs-operator absent from the "
          "subscribed catalog %s but the inventory lists it there"
          % scoped_label)
    sys.exit(20)
if present is False and listed_anywhere:
    print("NOTE: rhacs-operator is not in the subscribed catalog %s but is "
          "listed in %s; the catalog-scoped absence is consistent and is "
          "what the removal decision reads"
          % (scoped_label, ", ".join(listed_anywhere)))
PYEOF
}

run_assertions() {
  local failed=0 rc
  # (a) No classified evidence file may carry a probe_error or QUERY FAILED
  #     marker: a failed query must never read as a clean pass.
  #     The storage-axis captures (11-placementdecisions, 12 through 17)
  #     write no marker, so this check does not cover them.
  for f in "${EVIDENCE_DIR}/01-operatorpolicy.json" "${EVIDENCE_DIR}/02-catalogsource.json" "${EVIDENCE_DIR}/03-subscription.json" "${EVIDENCE_DIR}/05-csv.json" "${EVIDENCE_DIR}/07-central-cr.json" "${EVIDENCE_DIR}/08-packagemanifest-rhacs.json" "${EVIDENCE_DIR}/08-all-packagemanifests.txt" "${EVIDENCE_DIR}/11-acm-csv-addon-controller.json"; do
    if [[ ! -r "${f}" ]]; then
      echo "ASSERTION FAILURE (21): ${f} is missing or unreadable, evidence incomplete"
      failed=21
    fi
  # PRRT_kwDOBHvUUM65ui18: evidence file readability -r check
  done
  for f in "${EVIDENCE_DIR}"/*.json "${EVIDENCE_DIR}"/*.txt; do
    if grep -qE "^(probe_error:|QUERY FAILED)" "${f}" 2>/dev/null; then
      echo "ASSERTION FAILURE (21): ${f} carries a probe_error/QUERY FAILED marker, evidence incomplete"
      failed=21
    fi
  done
  if [[ "${_sub_refresh_failed}" == "true" ]]; then
    echo "ASSERTION FAILURE (21): the Subscription refresh failed, so the subscription terms are unknown"
    failed=21
  fi
  # The refresh overwrites 03-subscription.json, so a successful re-read would
  # otherwise hide that the capture this run started from failed. The refreshed
  # evidence is kept for diagnostics; the initial failure is reported here.
  if [[ "${_sub_initial_failed:-false}" == "true" ]]; then
    echo "ASSERTION FAILURE (21): the initial Subscription capture failed, so the subscription terms rest on the refresh alone (initial status kept in 03-subscription.initial-failed)"
    failed=21
  fi
  # (b) Packagemanifest agreement: the per-package capture is selected from
  #     the catalog the subscription subscribes to, so the inventory must
  #     list rhacs-operator in that catalog exactly when the capture reports
  #     it present. A package listed only in other catalogs is consistent
  #     with a catalog-scoped absence: reported, not failed (the removal
  #     decision needs to see it, but the artifacts agree).
  assert_packagemanifest_agreement || { rc=$?; [[ ${rc} -eq 20 ]] || rc=21; failed=$(( failed > rc ? failed : rc )); }
  # (c) Subscription capture must be OLM objects, not ACM's CRD.
  python3 - "${EVIDENCE_DIR}" <<'PYEOF' || { rc=$?; [[ ${rc} -eq 20 ]] || rc=21; failed=$(( failed > rc ? failed : rc )); }
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
# computation against embedded TRUE and FALSE fixtures, including the
# OperatorPolicy target binding (a different subscription fails, an unset
# field passes through). Run by setting ACS_EVIDENCE_SELF_TEST=1 (used in
# the PR rehearsal; exit 22 on failure).
self_test() {
  local tmp _st_failed=0
  tmp=$(mktemp -d)
  # Shared TRUE-fixture base: OperatorPolicy compliant, one subscription
  # (source redhat-operators) with one non-copied CSV in its namespace,
  # matching channel, and the packagemanifest in the subscribed catalog.
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
  "conditions": [], "channel": "stable", "source": "redhat-operators", "generation": 3}]
FIXTURE
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Succeeded", "reason": "Succeeded", "generation": 1}]' > "${tmp}/05-csv.json"
  echo '[{"name": "central", "namespace": "stackrox", "available": {"type": "Available", "status": "True"}}]' > "${tmp}/07-central-cr.json"
  echo '{"name": "rhacs-operator", "catalogSource": "redhat-operators", "catalogSourceNamespace": "openshift-marketplace", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.11.6"}]}' > "${tmp}/08-packagemanifest-rhacs.json"
  echo '[{"name": "advanced-cluster-management.v2.17.4", "version": "2.17.4", "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]}]' > "${tmp}/11-acm-csv-addon-controller.json"

  _term() {
    grep "^$1=" "${tmp}/acs-central-status.properties" | cut -d= -f2
  }
  _expect() {
    local val
    val=$(_term "$1")
    if [[ "${val}" != "$2" ]]; then
      echo "SELF-TEST FAILURE (22): $1=${val:-<unset>}, expected $2"
      _st_failed=1
    fi
  }

  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect removal_preconditions_met true
  _expect predicate_inputs_classified true
  # ACM build identity: both values come from the one CSV record.
  _expect acm_csv_version 2.17.4
  _expect addon_controller_image registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4

  # Split-record fixture: one CSV carries only the version, another only the
  # addon controller image. No single record supplies both, so neither value is
  # reported rather than pairing a version with another build's image.
  echo '[{"name": "advanced-cluster-management.v2.17.3", "namespace": "open-cluster-management", "phase": "Replacing", "version": "2.17.3", "governancePolicyAddonControllerImages": []},
        {"name": "advanced-cluster-management.v2.17.4", "namespace": "open-cluster-management", "phase": "Succeeded", "version": null, "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]}]' > "${tmp}/11-acm-csv-addon-controller.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect acm_csv_version unknown
  _expect addon_controller_image unknown
  # OLM copy fixture: the copy repeats the source version and images in
  # another namespace, so a selector that reads no reason sees two equally
  # qualifying Succeeded records and reports both values unknown.
  echo '[{"name": "advanced-cluster-management.v2.17.4", "namespace": "open-cluster-management", "phase": "Succeeded", "reason": null, "version": "2.17.4", "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]},
        {"name": "advanced-cluster-management.v2.17.4", "namespace": "policies", "phase": "Succeeded", "reason": "Copied", "version": "2.17.4", "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]}]' > "${tmp}/11-acm-csv-addon-controller.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect acm_csv_version 2.17.4
  _expect addon_controller_image registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4
  echo '[{"name": "advanced-cluster-management.v2.17.4", "version": "2.17.4", "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]}]' > "${tmp}/11-acm-csv-addon-controller.json"

  # Failed-query classification (a): a failed Central query must not read as
  # absence: distinct report values for denied vs absent.
  echo "QUERY FAILED (rc=1): simulated API denial" > "${tmp}/07-central-cr.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect central_query query_failed
  _expect central_present unknown
  _expect removal_preconditions_met false

  # Failed-query classification (b): a genuinely absent resource type reports
  # absence: a different value from the denied case.
  echo "CRD_ABSENT: centrals.platform.stackrox.io not registered on this cluster (successful query, resource type absent)" > "${tmp}/07-central-cr.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect central_query absent
  _expect central_present false

  # Catalog agreement: the package present only in a non-subscribed
  # catalog fails the precondition.
  echo '[{"name": "central", "namespace": "stackrox", "available": {"type": "Available", "status": "True"}}]' > "${tmp}/07-central-cr.json"
  echo '{"name": "rhacs-operator", "catalogSource": "community-operators", "catalogSourceNamespace": "openshift-marketplace", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.11.6"}]}' > "${tmp}/08-packagemanifest-rhacs.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect csv_catalog_matches_subscription false
  _expect removal_preconditions_met false

  # Catalog agreement (Copied CSV): a copied CSV in another namespace must not
  # count toward the precondition.
  echo '{"name": "rhacs-operator", "catalogSource": "redhat-operators", "catalogSourceNamespace": "openshift-marketplace", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.11.6"}]}' > "${tmp}/08-packagemanifest-rhacs.json"
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "policies", "phase": "Succeeded", "reason": "Copied"}]' > "${tmp}/05-csv.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect rhacs_csv_count 0
  _expect removal_preconditions_met false

  # FALSE fixture: no OperatorPolicy (today's 5.0 state). With the policy
  # absent there is nothing to target the subscription, so the term is false
  # rather than true by an unset field.
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Succeeded", "reason": "Succeeded"}]' > "${tmp}/05-csv.json"
  echo '[]' > "${tmp}/01-operatorpolicy.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_present false
  _expect operatorpolicy_targets_subscription false
  _expect removal_preconditions_met false

  # Per-term gating: a failed ops/subs/csvs query must not
  # read as confirmed absence in the report terms: unknown, not false/0.
  # A genuinely absent (CRD not registered) OperatorPolicy still reads false.
  echo "probe_error: subscription query failed" > "${tmp}/03-subscription.json"
  echo "probe_error: csv query failed" > "${tmp}/05-csv.json"
  echo "probe_error: operatorpolicy query failed" > "${tmp}/01-operatorpolicy.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_present unknown
  _expect operatorpolicy_targets_subscription unknown
  _expect rhacs_subscription_count unknown
  _expect rhacs_csv_count unknown
  _expect predicate_inputs_classified false
  _expect removal_preconditions_met false
  echo "CRD_ABSENT: operatorpolicies.policy.open-cluster-management.io not registered on this cluster" > "${tmp}/01-operatorpolicy.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_present false

  # Target binding: the policy must name this subscription. A declared and
  # different target fails the precondition; a field the policy leaves unset
  # does not constrain (pass-through).
  echo '[{"name": "rhacs-operator", "namespace": "rhacs-operator", "apiVersion": "operators.coreos.com/v1alpha1", "currentCSV": "rhacs-operator.v4.11.6", "state": "AtLatestKnown", "conditions": [], "channel": "stable", "source": "redhat-operators"}]' > "${tmp}/03-subscription.json"
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Succeeded", "reason": "Succeeded"}]' > "${tmp}/05-csv.json"
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies",
  "spec": {"subscriptionName": "advanced-cluster-management",
           "subscriptionNamespace": "open-cluster-management",
           "channel": "stable", "remediationAction": "enforce",
           "complianceType": "musthave"},
  "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_targets_subscription false
  _expect removal_preconditions_met false
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies",
  "spec": {"subscriptionName": null, "subscriptionNamespace": null,
           "channel": "stable", "remediationAction": "enforce",
           "complianceType": "musthave"},
  "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_targets_subscription false
  _expect removal_preconditions_met false

  # Enforcement gate: a compliant policy that only reports does not
  # re-create a removed subscription, so compliance plus a correct target is
  # not enough on its own.
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies",
  "spec": {"subscriptionName": "rhacs-operator",
           "subscriptionNamespace": "rhacs-operator",
           "channel": "stable", "remediationAction": "inform",
           "complianceType": "musthave"},
  "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_remediation_action inform
  _expect operatorpolicy_enforcing false
  _expect operatorpolicy_targets_subscription true
  _expect removal_preconditions_met false

  # A mustnothave policy works against the object's existence instead of
  # restoring it, so it cannot own the removal precondition either.
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies",
  "spec": {"subscriptionName": "rhacs-operator",
           "subscriptionNamespace": "rhacs-operator",
           "channel": "stable", "remediationAction": "enforce",
           "complianceType": "mustnothave"},
  "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_enforcing true
  _expect operatorpolicy_recreates_subscription false
  _expect removal_preconditions_met false

  # An unset enforcement field is unknown, not true by default: the capture
  # records the policy spec only, and enforcement can be overridden at a
  # level this step does not read.
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies",
  "spec": {"subscriptionName": "rhacs-operator",
           "subscriptionNamespace": "rhacs-operator",
           "channel": "stable", "remediationAction": null,
           "complianceType": null},
  "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect operatorpolicy_enforcing unknown
  _expect operatorpolicy_recreates_subscription unknown
  _expect removal_preconditions_met false

  # Upgrade-pending: the subscription resolves a newer CSV than the only
  # installed one, so the catalog is right and offers that version, yet the
  # upgrade has not landed. The installed CSV is not the CSV the subscription
  # resolves and cannot satisfy the precondition. Self-contained: every input
  # is restated here.
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
  "currentCSV": "rhacs-operator.v4.12.0", "state": "UpgradePending",
  "conditions": [], "channel": "stable", "source": "redhat-operators"}]
FIXTURE
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Succeeded", "reason": "Succeeded"}]' > "${tmp}/05-csv.json"
  echo '{"name": "rhacs-operator", "catalogSource": "redhat-operators", "catalogSourceNamespace": "openshift-marketplace", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.12.0"}]}' > "${tmp}/08-packagemanifest-rhacs.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect csv_catalog_matches_subscription true
  _expect packagemanifest_resolves_current_csv true
  _expect rhacs_subscription_channel stable
  _expect rhacs_csv_count 1
  _expect rhacs_csv_name rhacs-operator.v4.11.6
  _expect rhacs_csv_matches_subscription false
  _expect removal_preconditions_met false

  # Non-Succeeded phase: everything else is in its true form, but the
  # installed CSV has not finished installing. deploy-acs waits for
  # status.phase Succeeded before calling the operator deployed, so this
  # step cannot call the install settled. Self-contained: every input is
  # restated here.
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
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Installing", "reason": "Installing"}]' > "${tmp}/05-csv.json"
  echo '{"name": "rhacs-operator", "catalogSource": "redhat-operators", "catalogSourceNamespace": "openshift-marketplace", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.11.6"}]}' > "${tmp}/08-packagemanifest-rhacs.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect rhacs_csv_matches_subscription true
  _expect csv_catalog_matches_subscription true
  _expect packagemanifest_resolves_current_csv true
  _expect rhacs_csv_phase Installing
  _expect removal_preconditions_met false

  # Ambiguous OperatorPolicy: two policies match the same subscription
  # identity in different namespaces. The result must be order independent:
  # all operatorpolicy terms read as unknown and the predicate stays false.
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies", "spec": {"subscriptionName": "rhacs-operator", "subscriptionNamespace": "rhacs-operator", "channel": "stable", "remediationAction": "enforce", "complianceType": "musthave"}, "conditions": [{"type": "Compliant", "status": "True"}]}, {"name": "operatorpolicy-rhacs-operator", "namespace": "policies2", "spec": {"subscriptionName": "rhacs-operator", "subscriptionNamespace": "rhacs-operator", "channel": "stable", "remediationAction": "enforce", "complianceType": "musthave"}, "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  cat > "${tmp}/03-subscription.json" <<'FIXTURE'
[{"name": "rhacs-operator", "namespace": "rhacs-operator", "apiVersion": "operators.coreos.com/v1alpha1", "uid": "3f1c9e42-0000-4a1a-8a11-000000000001", "currentCSV": "rhacs-operator.v4.11.6", "state": "AtLatestKnown", "conditions": [], "channel": "stable", "source": "redhat-operators", "generation": 1}]
FIXTURE
  echo '[{"name": "rhacs-operator.v4.11.6", "namespace": "rhacs-operator", "phase": "Succeeded", "reason": "Succeeded", "generation": 1}]' > "${tmp}/05-csv.json"
  echo '[{"name": "central", "namespace": "stackrox", "available": {"type": "Available", "status": "True"}}]' > "${tmp}/07-central-cr.json"
  echo '{"name": "rhacs-operator", "catalogSource": "redhat-operators", "catalogSourceNamespace": "openshift-marketplace", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.11.6"}]}' > "${tmp}/08-packagemanifest-rhacs.json"
  echo '[{"name": "advanced-cluster-management.v2.17.4", "version": "2.17.4", "governancePolicyAddonControllerImages": [{"name": "governance-policy-addon-controller", "image": "registry.redhat.io/acm2/governance-policy-addon-controller-rhel9:v2.17.4"}]}]' > "${tmp}/11-acm-csv-addon-controller.json"
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect removal_preconditions_met false
  _expect operatorpolicy_present unknown
  _expect operatorpolicy_compliant unknown
  _expect operatorpolicy_targets_subscription unknown
  _expect operatorpolicy_enforcing unknown
  _expect operatorpolicy_recreates_subscription unknown
  _expect operatorpolicy_spec_channel unknown
  _expect operatorpolicy_remediation_action unknown
  _expect operatorpolicy_compliance_type unknown
  # Reverse list order must give the same result
  cat > "${tmp}/01-operatorpolicy.json" <<'FIXTURE'
[{"name": "operatorpolicy-rhacs-operator", "namespace": "policies2", "spec": {"subscriptionName": "rhacs-operator", "subscriptionNamespace": "rhacs-operator", "channel": "stable", "remediationAction": "enforce", "complianceType": "musthave"}, "conditions": [{"type": "Compliant", "status": "True"}]}, {"name": "operatorpolicy-rhacs-operator", "namespace": "policies", "spec": {"subscriptionName": "rhacs-operator", "subscriptionNamespace": "rhacs-operator", "channel": "stable", "remediationAction": "enforce", "complianceType": "musthave"}, "conditions": [{"type": "Compliant", "status": "True"}]}]
FIXTURE
  EVIDENCE_DIR="${tmp}" write_status_properties >/dev/null
  _expect removal_preconditions_met false
  _expect operatorpolicy_present unknown
  _expect operatorpolicy_compliant unknown
  _expect operatorpolicy_targets_subscription unknown
  _expect operatorpolicy_enforcing unknown
  _expect operatorpolicy_recreates_subscription unknown
  _expect operatorpolicy_spec_channel unknown

  # Inventory agreement: the selected package, catalog and catalog namespace
  # must appear together in the inventory.
  _st_assert_dir="${tmp}/inventory"
  mkdir -p "${_st_assert_dir}"
  cp "${tmp}/08-packagemanifest-rhacs.json" "${_st_assert_dir}/08-packagemanifest-rhacs.json"
  echo '[{"name": "rhacs-operator", "namespace": "rhacs-operator", "apiVersion": "operators.coreos.com/v1alpha1", "currentCSV": "rhacs-operator.v4.11.6", "channel": "stable", "source": "redhat-operators", "generation": 3}]' > "${_st_assert_dir}/03-subscription.json"
  printf '%s\n' 'rhacs-operator redhat-operators openshift-marketplace' > "${_st_assert_dir}/08-all-packagemanifests.txt"
  _st_expect_assert() { # <label> <expected-rc>
    local rc=0
    EVIDENCE_DIR="${_st_assert_dir}" assert_packagemanifest_agreement >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" != "$2" ]]; then
      echo "SELF-TEST FAILURE (22): inventory agreement [$1] returned ${rc}, expected $2"
      _st_failed=1
    fi
  }
  _st_expect_assert "tuple listed" 0

  # Cross-namespace fixture: the inventory lists rhacs-operator in
  # redhat-operators/openshift-marketplace and a DIFFERENT package in
  # redhat-operators/other-ns. A capture selecting rhacs-operator from
  # redhat-operators/other-ns must not pass on the catalog/namespace pair
  # alone, and the Subscription omits sourceNamespace so nothing else in the
  # check catches it.
  printf '%s\n' 'rhacs-operator redhat-operators openshift-marketplace' 'other-package redhat-operators other-ns' > "${_st_assert_dir}/08-all-packagemanifests.txt"
  echo '{"name": "rhacs-operator", "catalogSource": "redhat-operators", "catalogSourceNamespace": "other-ns", "channels": [{"name": "stable", "currentCSV": "rhacs-operator.v4.11.6"}]}' > "${_st_assert_dir}/08-packagemanifest-rhacs.json"
  _st_expect_assert "cross-namespace selection" 20

  # Same record present under the selection's namespace passes again.
  printf '%s\n' 'rhacs-operator redhat-operators openshift-marketplace' 'rhacs-operator redhat-operators other-ns' > "${_st_assert_dir}/08-all-packagemanifests.txt"
  _st_expect_assert "tuple listed in the selection namespace" 0
  rm -rf "${_st_assert_dir}"

  # Subscription snapshot stability: the early capture and the re-read must
  # describe the same object with the same fields.
  _st_early="${tmp}/sub-early.json"
  _st_late="${tmp}/sub-late.json"
  cp "${tmp}/03-subscription.json" "${_st_early}"
  cp "${tmp}/03-subscription.json" "${_st_late}"
  _st_expect_snapshot() { # <label> <expected>
    local got
    got=$(_sub_snapshot_state "$1" "$2")
    if [[ "${got}" != "$3" ]]; then
      echo "SELF-TEST FAILURE (22): snapshot state [$1] = ${got}, expected $3"
      _st_failed=1
    fi
  }
  _st_expect_snapshot "${_st_early}" "${_st_late}" same
  # Mutations are derived from the early capture, so the fixture suite stays
  # independent of which Subscription state the earlier fixtures left behind.
  _st_mutate() { # <mode: channel|generation|uid|missing-uid|extra-object>
    python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys

early, late, mode = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(early, encoding="utf-8"))
if mode == "channel":
    data[0]["channel"] = "stable-4.12"
elif mode == "generation":
    data[0]["generation"] = 99
elif mode == "uid":
    data[0]["uid"] = "3f1c9e42-0000-4a1a-8a11-000000000002"
elif mode == "missing-uid":
    data[0].pop("uid", None)
elif mode == "extra-object":
    extra = dict(data[0])
    extra["namespace"] = "other-ns"
    extra["currentCSV"] = "rhacs-operator.v9.9.9"
    extra["generation"] = 9
    data.append(extra)
json.dump(data, open(late, "w", encoding="utf-8"))
PYEOF
  }
  _st_mutate "${_st_early}" "${_st_late}" channel
  _st_expect_snapshot "${_st_early}" "${_st_late}" changed
  _st_mutate "${_st_early}" "${_st_late}" generation
  _st_expect_snapshot "${_st_early}" "${_st_late}" changed
  # A replacement object can resolve the same currentCSV with the same
  # generation: only the uid tells it from the object the run captured first.
  _st_mutate "${_st_early}" "${_st_late}" uid
  _st_expect_snapshot "${_st_early}" "${_st_late}" changed
  # A capture without a uid cannot prove object identity, so it is unknown
  # rather than same.
  _st_mutate "${_st_early}" "${_st_late}" missing-uid
  _st_expect_snapshot "${_st_early}" "${_st_late}" unknown
  # A different Subscription object appearing is not a change to this one.
  _st_mutate "${_st_early}" "${_st_late}" extra-object
  _st_expect_snapshot "${_st_early}" "${_st_late}" same
  rm -f "${_st_early}" "${_st_late}"

  # Error classification: only the API server's NotFound error shape counts
  # as absence, so a missing helper, a wrapper failure, or a denied request
  # can never be read as a confirmed absence.
  _st_check_class() { # _st_check_class <label> <expected> <rc> <text>
    local got=false
    oc_notfound "$3" "$4" && got=true
    if [[ "${got}" != "$2" ]]; then
      echo "SELF-TEST FAILURE (22): oc_notfound[$1]=${got}, expected $2"
      _st_failed=1
    fi
  }
  _st_check_class notfound-shape true 1 \
    'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "centrals.platform.stackrox.io" not found'
  _st_check_class list-notfound-shape true 1 \
    'Error from server (NotFound): the server could not find the requested resource'
  _st_check_class missing-helper false 127 \
    'bash: line 1: oc: command not found'
  _st_check_class wrapper-failure false 127 \
    'oc-wrapper: dependency not found in PATH'
  _st_check_class forbidden false 1 \
    'Error from server (Forbidden): centrals.platform.stackrox.io is forbidden: User "x" cannot list resource'
  _st_check_class unavailable false 1 \
    'Error from server (ServiceUnavailable): the server is currently unable to handle the request'
  _st_check_class zero-exit false 0 ''

  if [[ ${_st_failed} -ne 0 ]]; then
    rm -rf "${tmp}"
    return 22
  fi
  echo "SELF-TEST PASS: TRUE, query-failed, CRD-absent, catalog-mismatch, copied-CSV, target-mismatch, unset-target, no-OperatorPolicy, non-enforcing, removal-blocking, unspecified-enforcement, upgrade-pending, non-Succeeded-phase, ambiguous-OperatorPolicy, split-ACM-record, inventory-tuple, subscription-snapshot, and FALSE fixtures all classified correctly, and only the API server NotFound error shape classifies as absence"
  rm -rf "${tmp}"
  return 0
}

if [[ "${ACS_EVIDENCE_SELF_TEST:-0}" == "1" ]]; then
  self_test
  exit $?
fi

# 11. PlacementDecisions - cluster names only (INTEROP-9647 Stage 0: which
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

# 12. PVCs - name, namespace, StorageClass, requested size, phase
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

# 13. Nodes - role, age, pressure conditions, ephemeral-storage capacity.
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

# 14. MachineConfigPools - rollout state (the 9646 ENOSPC showed worker
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

# 15. StackRox DaemonSets - collector/sensor scheduling (desired vs ready)
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

# 16. workerocs machinesets - the policy-created nodes with small roots
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

# 17. ACS image footprint - container images of ACS deployments (operator
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
# Verdict counters use the fully-qualified OLM type: with ACM installed,
# bare `oc get subscription` resolves to ACM's CRD and counts nothing.
SUBSCRIPTION_COUNT=$(oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null | grep -ci "rhacs" 2>/dev/null || true)
SUBSCRIPTION_COUNT="${SUBSCRIPTION_COUNT:-0}"

set +x
CRD_CHECK=$(oc get crd centrals.platform.stackrox.io --no-headers 2>&1)
CRD_RC=$?
if [[ ${CRD_RC} -eq 0 ]]; then
  CRD_EXISTS="YES"
else
  if oc_notfound "${CRD_RC}" "${CRD_CHECK}"; then
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
  if [[ ${CR_RC} -eq 0 ]] || oc_notfound "${CR_RC}" "${CR_CHECK}" || \
     grep -qi "no resources" <<< "${CR_CHECK}"; then
    CENTRAL_EXISTS="NO"
  else
    CENTRAL_EXISTS="ERROR"
  fi
fi
set -x
echo "VERDICT: RHACS subscriptions=${SUBSCRIPTION_COUNT} CRD=${CRD_EXISTS} Central=${CENTRAL_EXISTS} workload-ns=${WORKLOAD_NS:-unknown} bundle=${BUNDLE_STATUS:-not-attempted} tls=${TLS_MODE:-not-attempted}"
_cat_rc=0
if ! cat "${EVIDENCE_DIR}/acs-central-status.properties"; then
  echo "ASSERTION FAILURE (21): acs-central-status.properties could not be read, so the removal predicate terms are missing from the evidence" >&2
  _cat_rc=21
fi

# Assertions run last so every capture is already on disk; a failure here
# fails the step (best_effort keeps the job green; finished.json carries it).
# _properties_rc and _cat_rc are carried through aggregation so a failed write/read
# cannot be masked by later passing assertions, while still running those
# checks for diagnostics.
run_assertions
ASSERT_RC=$?
if (( _properties_rc != 0 )); then
  ASSERT_RC=$(( ASSERT_RC > _properties_rc ? ASSERT_RC : _properties_rc ))
fi
if (( _cat_rc != 0 )); then
  ASSERT_RC=$(( ASSERT_RC > _cat_rc ? ASSERT_RC : _cat_rc ))
fi
if [[ ${ASSERT_RC} -ne 0 ]]; then
  echo "EVIDENCE ASSERTIONS FAILED (rc=${ASSERT_RC}): see messages above"
  exit ${ASSERT_RC}
fi
echo "EVIDENCE ASSERTIONS PASSED"
