#!/bin/bash

set +x
set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# --- OCM authentication ------------------------------------------------
# The ocm CLI accepts credentials only as command-line flags, so
# `ocm login --client-secret ...` publishes the secret in the process
# argument list. It reads the same credentials from its configuration file
# instead, so this step writes a private configuration and never passes a
# credential value on a command line or through the environment.
#
# `ocm login` cannot be combined with that configuration: it reassigns
# client_secret, user and password from its own (empty) flag values before
# connecting, which would discard the seeded credentials.
#
# Verified against the ocm 1.0.15 / rosa 1.2.64 binaries shipped in the
# rosa-aws-cli image used by this step:
#   - the only environment variables ocm honours are OCM_CONFIG, OCM_KEYRING
#     and OCM_URL; there is no environment or stdin input for a credential
#   - the configuration keys are client_id, client_secret, access_token,
#     refresh_token, token_url, url and scopes
#   - URL aliases are expanded only inside `ocm login`, so they are expanded
#     here and unknown values are rejected instead of being stored verbatim
#   - token_url has no default outside `ocm login` and must be set explicitly
#   - ocm get/post/patch/delete/token write the refreshed access and refresh
#     tokens back to the configuration file with mode 0600, so tokens stay
#     cached exactly as they were after `ocm login`
#   - rosa reads the same OCM_CONFIG file
OCM_SSO_TOKEN_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
OCM_DEFAULT_CLIENT_ID="cloud-services"
# This step has always validated credentials once, without a retry.
OCM_AUTH_ATTEMPTS=1
OCM_AUTH_DIR=""
OCM_AUTH_MODE="none"
OCM_TOKEN_FIELD=""
SSO_CLIENT_ID=""
SSO_CLIENT_SECRET=""
OCM_TOKEN=""

ocm_auth_cleanup() {
    if [[ -n "${OCM_AUTH_DIR:-}" && -d "${OCM_AUTH_DIR}" ]]; then
        rm -rf "${OCM_AUTH_DIR}"
    fi
    OCM_AUTH_DIR=""
}

# Render an untrusted value for logging: replace every non-printable byte so a
# value cannot inject extra log lines, bound the length, and double backslashes
# because log() renders its argument with `echo -e`.
log_safe() {
    local value="${1-}" max="${2:-200}" cleaned
    cleaned=$(printf '%s' "${value}" | tr -c '[:print:]' '?')
    if (( ${#cleaned} > max )); then
        cleaned="${cleaned:0:max}<truncated>"
    fi
    printf '%s' "${cleaned//\\/\\\\}"
}

# A client identifier is not a secret, but only a bounded prefix is logged so
# that a full identifier never reaches a public CI log.
ocm_client_id_prefix() {
    local id="${1-}"
    if [[ -z "${id}" ]]; then
        printf '%s' "<none>"
        return 0
    fi
    if (( ${#id} > 8 )); then
        printf '%s...' "$(log_safe "${id:0:8}" 8)"
        return 0
    fi
    log_safe "${id}" 8
}

# Expand an OCM environment to its API gateway URL. Unknown values are rejected
# rather than stored, because the configuration file accepts any string.
ocm_gateway_url() {
    local target_env="${1-}" gateway gateway_re
    # Alias lookup is case sensitive in the CLI (urls.OCMURLAliases), so it is
    # case sensitive here too.
    case "${target_env}" in
        production|prod|prd) printf '%s' "https://api.openshift.com"; return 0 ;;
        staging|stage|stg)   printf '%s' "https://api.stage.openshift.com"; return 0 ;;
        integration|int)     printf '%s' "https://api.integration.openshift.com"; return 0 ;;
    esac
    # A non-alias value used to reach urls.ResolveGatewayURL, which parses it
    # with url.ParseRequestURI and therefore lowercases the scheme, so an
    # HTTPS:// spelling reached the same gateway before this step expanded the
    # value itself. Normalize the scheme so it still does.
    gateway="${target_env}"
    if [[ "${gateway}" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]]; then
        gateway="https://${gateway#*://}"
    fi
    # A complete gateway URL is also accepted, but only a plain https URL: any
    # other shape could carry a control character into a log line or an
    # unintended endpoint into the configuration file. The authority stays
    # deliberately narrow, which is what keeps userinfo out; the path accepts
    # the full RFC 3986 pchar set (unreserved, sub-delims, ":" and "@") so a
    # legal gateway path is not rejected. "?", "#", whitespace and every
    # control character are still excluded.
    gateway_re="^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%!\$&'()*+,;=:@/-]*)?\$"
    if [[ "${gateway}" =~ ${gateway_re} ]]; then
        printf '%s' "${gateway}"
        return 0
    fi
    return 1
}

# Decode one base64url segment. The value never reaches a command line.
ocm_b64url_decode() {
    local data="${1-}"
    data="${data//-/+}"
    data="${data//_//}"
    case $(( ${#data} % 4 )) in
        1) return 1 ;;
        2) data="${data}==" ;;
        3) data="${data}=" ;;
    esac
    printf '%s' "${data}" | base64 -d 2>/dev/null
}

# Mirror the token classification `ocm login` performs: an encrypted token is
# stored as a refresh token, otherwise the JWT "typ" claim decides between an
# access token and a refresh token.
ocm_token_config_field() {
    local token="${1-}" dots payload typ payload_segment header
    dots="${token//[!.]/}"
    if (( ${#dots} == 4 )); then
        # config.IsEncryptedToken calls a five segment token encrypted only
        # when its first segment, padded with "==" and decoded with the
        # standard base64 alphabet, unmarshals into its JWETokenHeader with a
        # non-empty "enc" and a "cty" of JWT. That header's "alg", "enc" and
        # "cty" are string fields, so a present-but-non-string value fails the
        # unmarshal; require the same here. `ocm login` hands anything else to
        # its JWT parser, which rejects five segments, so reject it here
        # rather than staging a credential the CLI would refuse.
        if ! header=$(printf '%s==' "${token%%.*}" | base64 -d 2>/dev/null); then
            return 1
        fi
        if ! printf '%s' "${header}" | jq -e \
            'if type == "object" then (([.alg, .enc, .cty] | map(select(. != null)) | all(type == "string")) and (.enc // "") != "" and (.cty // "") == "JWT") else false end' \
            > /dev/null 2>&1; then
            return 1
        fi
        printf '%s' "refresh_token"
        return 0
    fi
    if (( ${#dots} != 2 )); then
        return 1
    fi
    # golang-jwt's ParseUnverified, which config.ParseToken calls, reads the
    # header before any claim and refuses a token whose header is not an
    # object with a string "alg". Which algorithm names it then accepts is
    # left to the CLI: an unregistered one is rejected on the first
    # validation, with the CLI's own message, rather than mirrored by a list
    # here that would drift from the parser the CLI was built against.
    if ! header=$(ocm_b64url_decode "${token%%.*}"); then
        return 1
    fi
    if ! printf '%s' "${header}" | jq -e \
        'if type == "object" then ((.alg | type) == "string" and .alg != "") else false end' \
        > /dev/null 2>&1; then
        return 1
    fi
    payload_segment="${token#*.}"
    payload_segment="${payload_segment%%.*}"
    if ! payload=$(ocm_b64url_decode "${payload_segment}"); then
        return 1
    fi
    # config.TokenType defaults only when the claim is absent: a present
    # "typ" that is not a string, including false and null, is an error there,
    # so `.typ // ""` must not quietly turn it into the Bearer default.
    if ! typ=$(printf '%s' "${payload}" |
        jq -er 'if type != "object" then error("not an object")
                elif (has("typ") | not) then ""
                elif (.typ | type) == "string" then .typ
                else error("non-string typ") end' 2>/dev/null); then
        return 1
    fi
    case "${typ}" in
        Bearer|"")       printf '%s' "access_token" ;;
        Refresh|Offline) printf '%s' "refresh_token" ;;
        *)               return 1 ;;
    esac
}

# Replace any credential value that a diagnostic may have echoed back.
ocm_redact() {
    local text="${1-}" stored
    if [[ -n "${SSO_CLIENT_SECRET}" ]]; then
        text="${text//"${SSO_CLIENT_SECRET}"/<redacted>}"
    fi
    if [[ -n "${OCM_TOKEN}" ]]; then
        text="${text//"${OCM_TOKEN}"/<redacted>}"
    fi
    # ocm writes the tokens it obtains back into the configuration file, so a
    # diagnostic can quote one that never came from the cluster profile.
    if [[ -n "${OCM_CONFIG:-}" && -s "${OCM_CONFIG:-}" ]]; then
        while IFS= read -r stored; do
            if [[ -n "${stored}" ]]; then
                text="${text//"${stored}"/<redacted>}"
            fi
        done < <(jq -r '(.access_token // ""), (.refresh_token // "")' "${OCM_CONFIG}" 2>/dev/null || true)
    fi
    printf '%s' "${text}"
}

# Choose the credential to use and stage it in a private directory. SSO client
# credentials keep precedence over the offline token, and a profile with
# neither is still a hard failure.
ocm_auth_prepare() {
    local old_umask
    OCM_AUTH_MODE="none"
    OCM_TOKEN_FIELD=""

    if [[ -n "${OCM_KEYRING:-}" ]]; then
        log "ERROR: OCM_KEYRING is set; the ocm CLI ignores OCM_CONFIG when a keyring is configured"
        return 1
    fi

    # ocm applies OCM_URL to every command except login, which would silently
    # send these calls somewhere other than the resolved gateway.
    if [[ -n "${OCM_URL:-}" ]]; then
        log "ERROR: OCM_URL is set; it would override the OCM environment this step resolved"
        return 1
    fi

    if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
        OCM_AUTH_MODE="sso-client"
    elif [[ -n "${OCM_TOKEN}" ]]; then
        OCM_AUTH_MODE="token"
        if ! OCM_TOKEN_FIELD=$(ocm_token_config_field "${OCM_TOKEN}"); then
            log "ERROR: the OCM token in the cluster profile is not a recognized access or refresh token"
            return 1
        fi
    else
        log "ERROR: No OCM credentials found in cluster profile (expected sso-client-id and sso-client-secret, or ocm-token)"
        return 1
    fi

    ocm_auth_cleanup
    old_umask=$(umask)
    umask 077
    if ! OCM_AUTH_DIR=$(mktemp -d); then
        umask "${old_umask}"
        log "ERROR: Failed to create a private directory for the OCM configuration"
        return 1
    fi
    # Remove the staged credentials on exit. Later traps in this script add
    # their own cleanup instead of clearing this one.
    trap 'ocm_auth_cleanup' EXIT
    chmod 700 "${OCM_AUTH_DIR}"
    OCM_CONFIG="${OCM_AUTH_DIR}/ocm.json"
    export OCM_CONFIG
    # Credential values are written to private files and handed to jq by path,
    # so no credential appears in a command line or in the environment. A short
    # write here would otherwise surface later as an authentication rejection.
    if ! { printf '%s' "${SSO_CLIENT_ID}" > "${OCM_AUTH_DIR}/client-id" &&
           printf '%s' "${SSO_CLIENT_SECRET}" > "${OCM_AUTH_DIR}/client-secret" &&
           printf '%s' "${OCM_TOKEN}" > "${OCM_AUTH_DIR}/token" &&
           : > "${OCM_CONFIG}" &&
           chmod 600 "${OCM_AUTH_DIR}/client-id" "${OCM_AUTH_DIR}/client-secret" \
                     "${OCM_AUTH_DIR}/token" "${OCM_CONFIG}"; }; then
        umask "${old_umask}"
        log "ERROR: Failed to stage the OCM credentials for the configuration file"
        return 1
    fi
    umask "${old_umask}"
    return 0
}

ocm_write_config() {
    local gateway_url="$1"
    if [[ "${OCM_AUTH_MODE}" == "sso-client" ]]; then
        jq -n \
            --rawfile client_id "${OCM_AUTH_DIR}/client-id" \
            --rawfile client_secret "${OCM_AUTH_DIR}/client-secret" \
            --arg token_url "${OCM_SSO_TOKEN_URL}" \
            --arg url "${gateway_url}" \
            '{client_id: $client_id, client_secret: $client_secret, token_url: $token_url, url: $url, scopes: ["openid"]}' \
            > "${OCM_CONFIG}"
        return
    fi
    # client_id matches what `ocm login --token` stores; the SDK would default
    # an absent value to the same identifier, but writing it keeps the
    # configuration identical to the one the CLI used to produce.
    jq -n \
        --rawfile token "${OCM_AUTH_DIR}/token" \
        --arg field "${OCM_TOKEN_FIELD}" \
        --arg client_id "${OCM_DEFAULT_CLIENT_ID}" \
        --arg token_url "${OCM_SSO_TOKEN_URL}" \
        --arg url "${gateway_url}" \
        '{($field): $token, client_id: $client_id, token_url: $token_url, url: $url, scopes: ["openid"]}' \
        > "${OCM_CONFIG}"
}

ocm_login() {
    local target_env="$1" attempt exit_code gateway_url gateway_display auth_error id_display
    if [[ "${OCM_AUTH_MODE}" == "none" || -z "${OCM_AUTH_DIR}" ]]; then
        return 1
    fi
    if ! gateway_url=$(ocm_gateway_url "${target_env}"); then
        # The rejected value is never quoted back: a URL carrying userinfo
        # (https://user:password@host) is exactly one of the shapes this guard
        # refuses, and its password is printable, so sanitizing it for logging
        # would not keep it out of a public CI log. Only its length is
        # reported, which distinguishes an empty setting from a typo.
        log "ERROR: Unsupported OCM environment (${#target_env} characters, value not logged); expected production|prod|prd|staging|stage|stg|integration|int or a full https:// gateway URL"
        return 1
    fi
    gateway_display=$(log_safe "${gateway_url}" 128)
    id_display="<none>"
    if [[ "${OCM_AUTH_MODE}" == "sso-client" ]]; then
        id_display=$(ocm_client_id_prefix "${SSO_CLIENT_ID}")
    fi
    log "OCM auth: mode=${OCM_AUTH_MODE} client-id-prefix=${id_display} target-env=$(log_safe "${target_env}" 64) gateway=${gateway_display}"
    for (( attempt = 1; attempt <= OCM_AUTH_ATTEMPTS; attempt++ )); do
        # `ocm token` saves the configuration it refreshed with a plain
        # truncate and write (config.Save calls os.WriteFile), so a save that
        # fails part way can leave OCM_CONFIG empty or incomplete. Stage the
        # seed configuration again for every attempt instead of letting a
        # later attempt read whatever the last one left behind.
        if ! ocm_write_config "${gateway_url}"; then
            # A failed write is transient storage trouble, not a bad
            # credential, and `ocm login` used to retry its own failed save,
            # so this costs an attempt and a backoff instead of ending the
            # login. `ocm token` is not run against a half written file.
            exit_code=1
            log "WARNING: Failed to write the OCM configuration for ${gateway_display} (attempt ${attempt}/${OCM_AUTH_ATTEMPTS})"
        elif ocm token > /dev/null 2> "${OCM_AUTH_DIR}/auth-error"; then
            CURRENT_OCM_ENV="${target_env}"
            : > "${OCM_AUTH_DIR}/auth-error"
            return 0
        else
            exit_code=$?
            auth_error=$(ocm_redact "$(cat "${OCM_AUTH_DIR}/auth-error" 2>/dev/null || true)")
            : > "${OCM_AUTH_DIR}/auth-error"
            log "WARNING: OCM credential validation failed for ${gateway_display} (attempt ${attempt}/${OCM_AUTH_ATTEMPTS}, exit ${exit_code}): $(log_safe "${auth_error}" 300)"
        fi
        if (( attempt >= OCM_AUTH_ATTEMPTS )); then
            log "ERROR: OCM authentication failed for ${gateway_display} after ${OCM_AUTH_ATTEMPTS} attempt(s) (mode=${OCM_AUTH_MODE}, exit ${exit_code})"
            return "${exit_code}"
        fi
        sleep 10
    done
    return 1
}

ocm_authenticate() {
    SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
    SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
    OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)
    CURRENT_OCM_ENV=""
    ocm_auth_prepare || return $?
    ocm_login "${OCM_LOGIN_ENV}"
}

ocm_ensure_env() {
    local target_env="$1"
    if [[ "${CURRENT_OCM_ENV}" == "${target_env}" ]]; then
        return 0
    fi
    ocm_login "${target_env}"
}

if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
    return 0
fi

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"
STALE_LEASE_HOURS="${STALE_LEASE_HOURS:-4}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

ocm_authenticate || exit $?

ALL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json)
TOTAL=$(echo "${ALL_CMS}" | jq '.items | length')

log "Lease health check: ${TOTAL} cluster(s) in inventory"

HEALTHY=0
UNHEALTHY=0
RECOVERED=0
NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=$((STALE_LEASE_HOURS * 3600))

REPORT="${ARTIFACT_DIR}/lease-health-report.txt"
echo "Lease Health Report - $(date -u)" > "${REPORT}"
echo "================================" >> "${REPORT}"

for i in $(seq 0 $((TOTAL - 1))); do
    CM=$(echo "${ALL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    STATUS=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    HOLDER=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    ACQUIRED_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')

    echo "" >> "${REPORT}"
    echo "Cluster: ${CM_NAME} (${CLUSTER_ID})" >> "${REPORT}"
    echo "  Status: ${STATUS}" >> "${REPORT}"

    if [[ "${STATUS}" == "in-use" && -n "${ACQUIRED_AT}" ]]; then
        ACQUIRED_EPOCH=$(date -d "${ACQUIRED_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ACQUIRED_AT}" +%s 2>/dev/null || echo "0")
        LEASE_AGE=$(( NOW_EPOCH - ACQUIRED_EPOCH ))

        if [[ ${LEASE_AGE} -gt ${STALE_THRESHOLD} ]]; then
            LEASE_HOURS=$(( LEASE_AGE / 3600 ))
            log "STALE LEASE: ${CM_NAME} held by ${HOLDER} for ${LEASE_HOURS}h (threshold: ${STALE_LEASE_HOURS}h)"
            echo "  STALE LEASE: held by ${HOLDER} for ${LEASE_HOURS}h" >> "${REPORT}"

            RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "available" },
                    "annotations": {
                        "rosa-cluster-lease/holder": "",
                        "rosa-cluster-lease/build-id": "",
                        "rosa-cluster-lease/released-at": "'"${RELEASED_AT}"'",
                        "rosa-cluster-lease/recovered-by": "health-check"
                    }
                }
            }'; then
                log "Recovered stale lease on ${CM_NAME}"
                echo "  RECOVERED: lease force-released" >> "${REPORT}"
                RECOVERED=$((RECOVERED + 1))
                STATUS="available"
            fi
        else
            log "${CM_NAME}: in-use by ${HOLDER} (${LEASE_AGE}s ago, within threshold)"
            echo "  Holder: ${HOLDER} (${LEASE_AGE}s ago)" >> "${REPORT}"
            HEALTHY=$((HEALTHY + 1))
            continue
        fi
    fi

    if [[ "${STATUS}" == "in-use" ]]; then
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Skip health checks for provisioning clusters
    if [[ "${STATUS}" == "provisioning" ]]; then
        HEALTHY=$((HEALTHY + 1))
        echo "  Provisioning (skipped)" >> "${REPORT}"
        continue
    fi

    CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    OCM_STATUS=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}" 2>/dev/null | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unreachable")
    echo "  OCM status: ${OCM_STATUS}" >> "${REPORT}"

    if [[ "${OCM_STATUS}" != "ready" ]]; then
        log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_STATUS}"

        if [[ "${STATUS}" != "error" ]]; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "OCM status: '"${OCM_STATUS}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    fi

    # --- ClusterPackage health check ---
    # Fetch a cluster-admin kubeconfig from OCM to inspect in-cluster state.
    # If the kubeconfig fetch fails (transient OCM issue, cluster not yet
    # accessible), skip the CP check — do NOT mark the cluster as error.
    CLUSTER_KUBECONFIG=$(mktemp)
    CP_CHECK_SKIPPED=""
    if ! ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null | jq -r '.kubeconfig' > "${CLUSTER_KUBECONFIG}" 2>/dev/null || [[ ! -s "${CLUSTER_KUBECONFIG}" ]]; then
        log "WARNING: ${CM_NAME} could not fetch cluster kubeconfig from OCM, skipping ClusterPackage check"
        CP_CHECK_SKIPPED="true"
    fi

    if [[ -z "${CP_CHECK_SKIPPED}" ]]; then
        # Determine the expected ClusterPackage set from the lease config
        CLUSTER_TYPE=$(echo "${CM}" | jq -r '.data["cluster-type"] // "classic-sts"')
        EXPECTED_CPS=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o jsonpath="{.data['expected-clusterpackages-${CLUSTER_TYPE}']}" 2>/dev/null || true)
        if [[ -z "${EXPECTED_CPS}" ]]; then
            EXPECTED_CPS=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o jsonpath='{.data.expected-clusterpackages}' 2>/dev/null || true)
        fi
        if [[ -z "${EXPECTED_CPS}" ]]; then
            # Default: the 8 managed operator ClusterPackages
            EXPECTED_CPS="configure-alertmanager-operator managed-node-metadata-operator managed-upgrade-operator ocm-agent-operator osd-metrics-exporter rbac-permissions-operator route-monitor-operator splunk-forwarder-operator"
        fi

        # Get actual ClusterPackages with the managed label from the cluster
        ACTUAL_CP_JSON=""
        ACTUAL_CP_JSON=$(oc --kubeconfig="${CLUSTER_KUBECONFIG}" get clusterpackage -l "hive.openshift.io/managed=true" --request-timeout=15s -o json 2>/dev/null) || true

        if [[ -n "${ACTUAL_CP_JSON}" ]]; then
            # Check for missing CPs (expected but not present)
            ACTUAL_CP_NAMES=$(echo "${ACTUAL_CP_JSON}" | jq -r '.items[].metadata.name' 2>/dev/null | sort) || true
            CP_ISSUES=""
            for expected_cp in ${EXPECTED_CPS}; do
                if ! echo "${ACTUAL_CP_NAMES}" | grep -qx "${expected_cp}"; then
                    CP_ISSUES="${CP_ISSUES}missing:${expected_cp} "
                fi
            done

            # Check for degraded CPs (present but Available != True)
            DEGRADED_CPS=$(echo "${ACTUAL_CP_JSON}" | jq -r '
                .items[] |
                select(any(.status.conditions[]?;
                    .type == "Available" and .status == "True") | not) |
                .metadata.name' 2>/dev/null) || true
            for degraded_cp in ${DEGRADED_CPS}; do
                CP_ISSUES="${CP_ISSUES}degraded:${degraded_cp} "
            done

            if [[ -n "${CP_ISSUES}" ]]; then
                CP_ISSUES="${CP_ISSUES% }"
                log "UNHEALTHY: ${CM_NAME} ClusterPackage issues: ${CP_ISSUES}"
                echo "  ClusterPackage issues: ${CP_ISSUES}" >> "${REPORT}"
                if [[ "${STATUS}" != "error" ]]; then
                    lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                        "metadata": {
                            "labels": { "rosa-cluster-lease/status": "error" },
                            "annotations": { "rosa-cluster-lease/error-reason": "ClusterPackage: '"${CP_ISSUES}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                        }
                    }' || true
                fi
                rm -f "${CLUSTER_KUBECONFIG}"
                UNHEALTHY=$((UNHEALTHY + 1))
                continue
            fi
        else
            log "WARNING: ${CM_NAME} could not list ClusterPackages, skipping CP check"
        fi
    fi
    rm -f "${CLUSTER_KUBECONFIG}"
    # --- End ClusterPackage health check ---

    if [[ "${STATUS}" == "error" ]]; then
        log "RESTORED: ${CM_NAME} is healthy again, setting to available"
        lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
            "metadata": {
                "labels": { "rosa-cluster-lease/status": "available" },
                "annotations": { "rosa-cluster-lease/error-reason": "", "rosa-cluster-lease/error-at": "" }
            }
        }' || true
        echo "  RESTORED to available" >> "${REPORT}"
    fi

    HEALTHY=$((HEALTHY + 1))
done

echo "" >> "${REPORT}"
echo "Summary: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} recovered" >> "${REPORT}"

log "Lease health check complete: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} stale leases recovered"
cat "${REPORT}"
