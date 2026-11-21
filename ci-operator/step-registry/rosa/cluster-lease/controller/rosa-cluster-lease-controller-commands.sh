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
# Credential validation keeps the three attempt retry this step has always used.
OCM_AUTH_ATTEMPTS=3
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
STALE_LEASE_HOURS="${STALE_LEASE_HOURS:-1}"
ERROR_REPLACE_HOURS="${ERROR_REPLACE_HOURS:-1}"
MAX_CLUSTER_AGE_HOURS="${MAX_CLUSTER_AGE_HOURS:-0}"
REFRESH_DAY="${REFRESH_DAY:-6}"
MAX_REFRESH_PER_RUN="${MAX_REFRESH_PER_RUN:-2}"
DRY_RUN="${DRY_RUN:-false}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

dry_run_guard() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY RUN: $*"
        return 0
    fi
    return 1
}

ocm_get_cluster() {
    local name="$1" response=""
    if ! response=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name = '${name}'" 2>&1); then
        log "ERROR: OCM lookup failed for ${name}: ${response}"
        return 1
    fi
    echo "${response}" | jq '.items[0] // empty' 2>/dev/null
}

# Query OCM for a cluster by ID. Sets globals:
#   OCM_CHECK_RESULT: "unreachable", "not-found", or "ok"
#   OCM_CHECK_STATUS: cluster state (e.g. "ready", "installing") when result is "ok"
#   OCM_CHECK_RESPONSE: full JSON response when result is "ok"
ocm_check_cluster() {
    local cluster_id="$1" ocm_env="${2:-staging}"
    OCM_CHECK_RESULT="" OCM_CHECK_STATUS="" OCM_CHECK_RESPONSE=""
    ocm_ensure_env "${ocm_env}" || return $?
    local response rc
    if response=$(ocm get /api/clusters_mgmt/v1/clusters/"${cluster_id}" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    if [[ -z "${response}" ]]; then
        OCM_CHECK_RESULT="unreachable"
        return
    fi
    local ocm_id
    ocm_id=$(echo "${response}" | jq -r '.id // ""' 2>/dev/null || true)
    if [[ "${ocm_id}" == "404" ]]; then
        OCM_CHECK_RESULT="not-found"
        return
    fi
    if (( rc != 0 )) || [[ -z "${ocm_id}" ]]; then
        OCM_CHECK_RESULT="unreachable"
        return
    fi
    OCM_CHECK_RESULT="ok"
    OCM_CHECK_STATUS=$(echo "${response}" | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unknown")
    OCM_CHECK_RESPONSE="${response}"
}

register_lease() {
    local name="$1" status="$2" cluster_id="$3" type="$4" env="$5" region="$6" version="$7"
    local api_url="${8:-}" actual_version="${9:-}"
    lease_oc apply -n "${LEASE_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}
  namespace: ${LEASE_NAMESPACE}
  labels:
    rosa-cluster-lease/managed: "true"
    rosa-cluster-lease/type: ${type}
    rosa-cluster-lease/env: ${env}
    rosa-cluster-lease/region: ${region}
    rosa-cluster-lease/version: "${version}"
    rosa-cluster-lease/status: ${status}
  annotations:
    rosa-cluster-lease/holder: ""
    rosa-cluster-lease/build-id: ""
    rosa-cluster-lease/acquired-at: ""
    rosa-cluster-lease/released-at: ""
    rosa-cluster-lease/registered-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
data:
  cluster-id: "${cluster_id}"
  cluster-name: "${name}"
  api-url: "${api_url}"
  region: "${region}"
  version: "${actual_version}"
  ocm-env: "${env}"
EOF
}

# Configure cloud credentials from cluster profile
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
fi
export AWS_REGION="${AWS_REGION:-us-east-1}"

GCP_CREDENTIALS_FILE="${GCP_CREDENTIALS_FILE:-/etc/rosa-e2e-gcp/osd-ccs-gcp.json}"
OSD_AWS_CREDENTIALS_DIR="${OSD_AWS_CREDENTIALS_DIR:-/etc/rosa-e2e-osd-aws}"

# Resolve the latest available version for a given cloud provider and version prefix
resolve_version() {
    local type="$1" version_prefix="$2" channel="${3:-stable}"
    if [[ "${type}" == "osd-gcp" ]]; then
        ocm get /api/clusters_mgmt/v1/versions \
            --parameter search="enabled = 'true' AND raw_id like '${version_prefix}%' AND channel_group = '${channel}' AND gcp_marketplace_enabled = 'true'" \
            --parameter size=100 2>/dev/null \
            | jq -r '.items[].raw_id // empty' 2>/dev/null \
            | sort -V | tail -n1
    elif [[ "${type}" == "osd-aws" ]]; then
        ocm get /api/clusters_mgmt/v1/versions \
            --parameter search="enabled = 'true' AND raw_id like '${version_prefix}%' AND channel_group = '${channel}'" \
            --parameter size=100 2>/dev/null \
            | jq -r '.items[].raw_id // empty' 2>/dev/null \
            | sort -V | tail -n1
    else
        rosa list versions --channel-group "${channel}" -o json 2>/dev/null \
            | jq -r '.[] | select(.enabled == true) | select(.raw_id | startswith("'"${version_prefix}"'")) | .raw_id' \
            | sort -V | tail -n1
    fi
}

# Provision a cluster based on its type
provision_cluster() {
    local name="$1" type="$2" region="$3" version="$4" channel="$5"
    local compute_nodes="$6" machine_type="$7"
    local cluster_json="$8" desired_cm="$9"

    if [[ "${type}" == "osd-gcp" ]]; then
        provision_gcp_cluster "${name}" "${region}" "${version}" "${channel}" "${compute_nodes}" "${machine_type}"
    elif [[ "${type}" == "osd-aws" ]]; then
        provision_osd_aws_cluster "${name}" "${region}" "${version}" "${channel}" "${compute_nodes}" "${machine_type}"
    else
        provision_sts_cluster "${name}" "${region}" "${version}" "${channel}" "${compute_nodes}" "${machine_type}" "${cluster_json}" "${desired_cm}"
    fi
}

provision_gcp_cluster() {
    local name="$1" region="$2" version="$3" channel="$4"
    local compute_nodes="$5" machine_type="$6"

    if [[ ! -f "${GCP_CREDENTIALS_FILE}" ]]; then
        log "WARNING: GCP credentials not found at ${GCP_CREDENTIALS_FILE}. Skipping ${name}."
        return 1
    fi

    ocm create cluster "${name}" \
        --ccs \
        --provider gcp \
        --service-account-file "${GCP_CREDENTIALS_FILE}" \
        --region "${region}" \
        --version "${version}" \
        --channel-group "${channel}" \
        --compute-machine-type "${machine_type}" \
        --compute-nodes "${compute_nodes}" \
        || { log "ERROR: Failed to create GCP cluster ${name}"; return 1; }
}

provision_osd_aws_cluster() {
    local name="$1" region="$2" version="$3" channel="$4"
    local compute_nodes="$5" machine_type="$6"

    local cred_file="${OSD_AWS_CREDENTIALS_DIR}/credentials"
    if [[ ! -f "${cred_file}" ]]; then
        log "WARNING: OSD AWS CCS credentials not found at ${cred_file}. Skipping ${name}."
        return 1
    fi

    local aws_access_key_id aws_secret_access_key
    aws_access_key_id=$(grep -m1 'aws_access_key_id' "${cred_file}" | cut -d= -f2 | tr -d ' ')
    aws_secret_access_key=$(grep -m1 'aws_secret_access_key' "${cred_file}" | cut -d= -f2 | tr -d ' ')

    if [[ -z "${aws_access_key_id}" || -z "${aws_secret_access_key}" ]]; then
        log "WARNING: Could not parse AWS credentials from ${cred_file}. Skipping ${name}."
        return 1
    fi

    local aws_account_id
    aws_account_id=$(AWS_SHARED_CREDENTIALS_FILE="${cred_file}" aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    if [[ -z "${aws_account_id}" ]]; then
        log "WARNING: Cannot determine AWS account ID for osdCcsAdmin. Skipping ${name}."
        return 1
    fi

    ocm create cluster "${name}" \
        --ccs \
        --provider aws \
        --aws-account-id "${aws_account_id}" \
        --aws-access-key-id "${aws_access_key_id}" \
        --aws-secret-access-key "${aws_secret_access_key}" \
        --region "${region}" \
        --version "${version}" \
        --channel-group "${channel}" \
        --compute-machine-type "${machine_type}" \
        --compute-nodes "${compute_nodes}" \
        || { log "ERROR: Failed to create OSD AWS cluster ${name}"; return 1; }
}

provision_sts_cluster() {
    local name="$1" region="$2" version="$3" channel="$4"
    local compute_nodes="$5" machine_type="$6"
    local cluster_json="$7" desired_cm="$8"

    local oidc_config_id role_prefix aws_account_id

    oidc_config_id=$(echo "${cluster_json}" | jq -r '.["oidc-config-id"] // empty')
    if [[ -z "${oidc_config_id}" ]]; then
        oidc_config_id=$(echo "${desired_cm}" | jq -r '.data["oidc-config-id"] // empty')
    fi
    if [[ -z "${oidc_config_id}" ]]; then
        log "WARNING: No oidc-config-id for ${name}. Skipping."
        return 1
    fi

    role_prefix=$(echo "${cluster_json}" | jq -r '.["account-role-prefix"] // empty')
    if [[ -z "${role_prefix}" ]]; then
        role_prefix=$(echo "${desired_cm}" | jq -r '.data["account-role-prefix"] // "rosa-lease"')
    fi

    aws_account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
    if [[ -z "${aws_account_id}" ]]; then
        log "WARNING: Cannot determine AWS account ID. Skipping ${name}."
        return 1
    fi

    if ! rosa delete operator-roles --prefix "${name}" -y --mode auto; then
        log "ERROR: Failed to delete stale operator roles for ${name}. Skipping cluster creation."
        return 1
    fi

    rosa create cluster -y \
        --cluster-name "${name}" \
        --sts \
        --mode auto \
        --region "${region}" \
        --version "${version}" \
        --channel-group "${channel}" \
        --compute-nodes "${compute_nodes}" \
        --compute-machine-type "${machine_type}" \
        --role-arn "arn:aws:iam::${aws_account_id}:role/${role_prefix}-Installer-Role" \
        --support-role-arn "arn:aws:iam::${aws_account_id}:role/${role_prefix}-Support-Role" \
        --worker-iam-role "arn:aws:iam::${aws_account_id}:role/${role_prefix}-Worker-Role" \
        --controlplane-iam-role "arn:aws:iam::${aws_account_id}:role/${role_prefix}-ControlPlane-Role" \
        --oidc-config-id "${oidc_config_id}" \
        --operator-roles-prefix "${name}" \
        --tags "rosa-cluster-lease:true,lease-managed:true" \
        || { log "ERROR: Failed to create cluster ${name}"; return 1; }
}

# Delete a cluster based on its type
delete_cluster() {
    local cluster_id="$1" type="$2"
    if [[ "${type}" == "osd-gcp" || "${type}" == "osd-aws" ]]; then
        ocm delete "/api/clusters_mgmt/v1/clusters/${cluster_id}"
    else
        local cluster_desc roles_prefix oidc_config_id describe_attempt
        for describe_attempt in $(seq 1 5); do
            if [[ "${describe_attempt}" -lt 5 ]]; then
                cluster_desc=$(rosa describe cluster -c "${cluster_id}" -o json 2>/dev/null || true)
            else
                local describe_err="/tmp/rosa-describe-err.$$"
                cluster_desc=$(rosa describe cluster -c "${cluster_id}" -o json 2>"${describe_err}" || true)
                if [[ -z "${cluster_desc}" && -s "${describe_err}" ]]; then
                    log "DEBUG: rosa describe cluster stderr: $(cat "${describe_err}")"
                fi
                rm -f "${describe_err}"
            fi
            if [[ -n "${cluster_desc}" ]]; then
                break
            fi
            log "WARNING: Failed to describe cluster ${cluster_id} (attempt ${describe_attempt}/5)"
            sleep 10
        done
        if [[ -z "${cluster_desc}" ]]; then
            log "ERROR: Failed to describe cluster ${cluster_id} after 5 attempts, skipping deletion"
            return 1
        fi
        roles_prefix=$(echo "${cluster_desc}" | jq -r '.aws.sts.operator_role_prefix // empty' 2>/dev/null || true)
        oidc_config_id=$(echo "${cluster_desc}" | jq -r '.aws.sts.oidc_config.id // empty' 2>/dev/null || true)

        rosa delete cluster -c "${cluster_id}" -y
        log "Waiting for cluster ${cluster_id} to be fully removed before cleaning up IAM resources..."
        local wait_attempt
        for wait_attempt in $(seq 1 60); do
            ocm_check_cluster "${cluster_id}" "${CURRENT_OCM_ENV}"
            if [[ "${OCM_CHECK_RESULT}" == "not-found" ]]; then
                log "Cluster ${cluster_id} fully removed"
                break
            fi
            if [[ "${OCM_CHECK_RESULT}" == "unreachable" ]]; then
                log "WARNING: Unable to confirm removal of cluster ${cluster_id} (attempt ${wait_attempt}/60)"
            else
                log "  Cluster ${cluster_id} still being removed (attempt ${wait_attempt}/60)"
            fi
            sleep 60
        done
        if [[ "${OCM_CHECK_RESULT}" != "not-found" ]]; then
            log "ERROR: Cluster ${cluster_id} removal was not confirmed after 60 attempts, skipping IAM cleanup"
            return 1
        fi
        if [[ -n "${roles_prefix}" ]]; then
            rosa delete operator-roles --prefix "${roles_prefix}" -y --mode auto || true
        fi
        if [[ -n "${oidc_config_id}" ]]; then
            rosa delete oidc-provider --oidc-config-id "${oidc_config_id}" -y --mode auto || true
        fi
    fi
}

# List available upgrades for a cluster
list_upgrades() {
    local cluster_id="$1" type="$2" desired_version="$3"
    if [[ "${type}" == "osd-gcp" || "${type}" == "osd-aws" ]]; then
        ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}" 2>/dev/null \
            | jq -r --arg desired "${desired_version}" \
              '.version.available_upgrades[] | select(startswith($desired))' 2>/dev/null \
            | sort -V | tail -n1
    else
        rosa list upgrades -c "${cluster_id}" -o json 2>/dev/null \
            | jq -r --arg desired "${desired_version}" \
              '.[] | select(.version | startswith($desired)) | .version' 2>/dev/null \
            | sort -V | tail -n1
    fi
}

# Schedule an upgrade for a cluster
schedule_upgrade() {
    local cluster_id="$1" type="$2" target_version="$3"
    local next_run
    next_run=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "${type}" == "osd-gcp" || "${type}" == "osd-aws" ]]; then
        echo "{\"version\": \"${target_version}\", \"schedule_type\": \"manual\", \"next_run\": \"${next_run}\"}" \
            | ocm post "/api/clusters_mgmt/v1/clusters/${cluster_id}/upgrade_policies"
    else
        rosa upgrade cluster -c "${cluster_id}" \
            --version "${target_version}" \
            --schedule-date "$(date -u +%Y-%m-%d)" \
            --schedule-time "$(date -u +%H:%M)" \
            -y
    fi
}

ocm_authenticate || exit $?

NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=$((STALE_LEASE_HOURS * 3600))
ERROR_THRESHOLD=$((ERROR_REPLACE_HOURS * 3600))
REPORT="${ARTIFACT_DIR}/controller-report.txt"
echo "Lease Controller Report - $(date -u)" > "${REPORT}"
echo "======================================" >> "${REPORT}"

# ---------------------------------------------------------------
# Phase 1: Read desired state
# ---------------------------------------------------------------
log "Phase 1: Reading desired state"

DESIRED_CM=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o json 2>/dev/null || echo "")
if [[ -z "${DESIRED_CM}" ]]; then
    log "ERROR: rosa-cluster-lease-config ConfigMap not found in ${LEASE_NAMESPACE}"
    log "Create it with a 'desired-clusters' data key containing YAML cluster definitions"
    exit 1
fi

if ! DESIRED_YAML=$(echo "${DESIRED_CM}" | jq -er '.data["desired-clusters"]'); then
    log "ERROR: desired-clusters key missing from rosa-cluster-lease-config"
    exit 1
fi

if ! DESIRED_NAMES=$(echo "${DESIRED_YAML}" | python3 -c "
import sys, json, re

def parse_yaml_list(text):
    clusters, current = [], {}
    for line in text.strip().split('\n'):
        m = re.match(r'\s*-\s+([\w][\w-]*):\s*(.*)', line)
        if m:
            if current: clusters.append(current)
            current = {m.group(1): m.group(2).strip().strip('\"')}
            continue
        m = re.match(r'\s+([\w][\w-]*):\s*(.*)', line)
        if m:
            current[m.group(1)] = m.group(2).strip().strip('\"')
        elif line.strip() and not line.lstrip().startswith('#'):
            raise ValueError(f'Unexpected line: {line!r}')
    if current: clusters.append(current)
    return clusters

for c in parse_yaml_list(sys.stdin.read()):
    print(json.dumps(c))
"); then
    log "ERROR: Failed to parse desired-clusters YAML"
    exit 1
fi

DESIRED_COUNT=$(echo "${DESIRED_NAMES}" | grep -c '{' || echo "0")
if [[ "${DESIRED_COUNT}" -eq 0 ]]; then
    log "ERROR: desired-clusters is empty, refusing to reconcile (would decommission all clusters)"
    exit 1
fi
log "Desired clusters: ${DESIRED_COUNT}"

# ---------------------------------------------------------------
# Phase 2: Read actual state
# ---------------------------------------------------------------
log "Phase 2: Reading actual state"

ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
ACTUAL_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')
log "Actual clusters: ${ACTUAL_COUNT}"

# ---------------------------------------------------------------
# Phase 3: Provision missing clusters
# ---------------------------------------------------------------
log "Phase 3: Checking for missing clusters"

while IFS= read -r cluster_json; do
    [[ -z "${cluster_json}" ]] && continue

    NAME=$(echo "${cluster_json}" | jq -r '.name')
    ENV=$(echo "${cluster_json}" | jq -r '.env // "staging"')
    REGION=$(echo "${cluster_json}" | jq -r '.region // "us-east-1"')
    TYPE=$(echo "${cluster_json}" | jq -r '.type // "classic-sts"')
    VERSION=$(echo "${cluster_json}" | jq -r '.version // "4.22"')
    CHANNEL=$(echo "${cluster_json}" | jq -r '.["channel-group"] // "stable"')
    COMPUTE_NODES=$(echo "${cluster_json}" | jq -r '.["compute-nodes"] // "2"')
    MACHINE_TYPE=$(echo "${cluster_json}" | jq -r '.["machine-type"] // "m5.xlarge"')

    # Check if cluster already tracked in lease inventory
    EXISTING=$(echo "${ACTUAL_CMS}" | jq -r ".items[] | select(.metadata.name == \"${NAME}\") | .metadata.name" 2>/dev/null || true)
    if [[ -n "${EXISTING}" ]]; then
        continue
    fi

    # Log in to the right OCM environment for this cluster
    ocm_ensure_env "${ENV}"

    # Check if cluster already exists in OCM (e.g. previous run timed out before registering)
    if ! OCM_CLUSTER_JSON=$(ocm_get_cluster "${NAME}"); then
        log "WARNING: OCM lookup failed for ${NAME}, skipping to avoid duplicate provisioning"
        continue
    fi
    OCM_CLUSTER_ID=$(echo "${OCM_CLUSTER_JSON}" | jq -r '.id // empty' 2>/dev/null || true)

    if [[ -n "${OCM_CLUSTER_ID}" ]]; then
        OCM_STATE=$(echo "${OCM_CLUSTER_JSON}" | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unknown")
        log "FOUND: ${NAME} already exists in OCM (id=${OCM_CLUSTER_ID}, state=${OCM_STATE})"

        if [[ "${OCM_STATE}" == "ready" ]]; then
            API_URL=$(echo "${OCM_CLUSTER_JSON}" | jq -r '.api.url // ""')
            ACTUAL_VERSION=$(echo "${OCM_CLUSTER_JSON}" | jq -r '.openshift_version // ""')
            VERSION_LABEL=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)
            CLUSTER_HREF=$(echo "${OCM_CLUSTER_JSON}" | jq -r '.href // empty')
            log "REGISTER: ${NAME} is ready, registering in lease inventory"
            if ! dry_run_guard "Would register ${NAME}"; then
                register_lease "${NAME}" "available" "${OCM_CLUSTER_ID}" "${TYPE}" "${ENV}" "${REGION}" "${VERSION_LABEL}" "${API_URL}" "${ACTUAL_VERSION}"
                log "Registered ${NAME} (${OCM_CLUSTER_ID}) in lease inventory"
                # Set expiration to +28 days to prevent OCM auto-deletion
                if [[ -n "${CLUSTER_HREF}" ]]; then
                    EXPIRATION=$(date -u -d "+28 days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+28d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
                    if [[ -n "${EXPIRATION}" ]]; then
                        if echo "{\"expiration_timestamp\": \"${EXPIRATION}\"}" | ocm patch "${CLUSTER_HREF}" 2>/dev/null; then
                            log "Set expiration for ${NAME} to ${EXPIRATION}"
                        else
                            log "WARNING: Failed to set expiration for ${NAME} (org may need bypass_max_expiration capability)"
                        fi
                    fi
                fi
            fi
            echo "REGISTERED: ${NAME} (already ready in OCM)" >> "${REPORT}"
        elif [[ "${OCM_STATE}" == "installing" || "${OCM_STATE}" == "pending" || "${OCM_STATE}" == "waiting" ]]; then
            log "WAITING: ${NAME} is ${OCM_STATE}, registering as provisioning"
            if ! dry_run_guard "Would register ${NAME} as provisioning"; then
                register_lease "${NAME}" "provisioning" "${OCM_CLUSTER_ID}" "${TYPE}" "${ENV}" "${REGION}" "${VERSION}"
            fi
            echo "PROVISIONING: ${NAME} (already ${OCM_STATE} in OCM)" >> "${REPORT}"
        elif [[ "${OCM_STATE}" == "error" || "${OCM_STATE}" == "uninstalling" ]]; then
            log "ERROR: ${NAME} is in ${OCM_STATE} state, registering as error for replacement"
            if ! dry_run_guard "Would register ${NAME} as error"; then
                register_lease "${NAME}" "error" "${OCM_CLUSTER_ID}" "${TYPE}" "${ENV}" "${REGION}" "${VERSION}"
            fi
            echo "ERROR: ${NAME} state=${OCM_STATE}" >> "${REPORT}"
        else
            log "WARNING: ${NAME} exists in OCM with unexpected state ${OCM_STATE}"
            echo "UNEXPECTED: ${NAME} state=${OCM_STATE}" >> "${REPORT}"
        fi
        continue
    fi

    log "PROVISION: ${NAME} (${TYPE}, ${ENV}, ${REGION}, ${VERSION})"
    echo "PROVISION: ${NAME} env=${ENV} region=${REGION} version=${VERSION} type=${TYPE}" >> "${REPORT}"

    if dry_run_guard "Would provision ${NAME}"; then
        continue
    fi

    FULL_VERSION=$(resolve_version "${TYPE}" "${VERSION}" "${CHANNEL}")
    if [[ -z "${FULL_VERSION}" ]]; then
        log "WARNING: No available version matching ${VERSION} in ${CHANNEL} for ${TYPE}. Skipping ${NAME}."
        continue
    fi
    log "Resolved version: ${FULL_VERSION}"

    if ! provision_cluster "${NAME}" "${TYPE}" "${REGION}" "${FULL_VERSION}" "${CHANNEL}" \
        "${COMPUTE_NODES}" "${MACHINE_TYPE}" "${cluster_json}" "${DESIRED_CM}"; then
        continue
    fi

    # Register immediately as provisioning
    CLUSTER_ID=$(ocm_get_cluster "${NAME}" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -n "${CLUSTER_ID}" ]]; then
        register_lease "${NAME}" "provisioning" "${CLUSTER_ID}" "${TYPE}" "${ENV}" "${REGION}" "${VERSION}"
    fi

    # Wait for cluster to be ready (up to 60 min)
    log "Waiting for ${NAME} to be ready..."
    for attempt in $(seq 1 60); do
        STATE=$(ocm_get_cluster "${NAME}" | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unknown")
        if [[ "${STATE}" == "ready" ]]; then
            break
        fi
        if [[ "${STATE}" == "error" ]]; then
            log "ERROR: Cluster ${NAME} entered error state during provisioning"
            break
        fi
        log "  ${NAME}: state=${STATE} (attempt ${attempt}/60)"
        sleep 60
    done

    if [[ "${STATE}" != "ready" ]]; then
        log "WARNING: ${NAME} not ready after 60 min (state: ${STATE}). Will retry next reconcile."
        continue
    fi

    # Update lease to available with full cluster details
    if ! CLUSTER_JSON=$(ocm_get_cluster "${NAME}"); then
        log "WARNING: OCM lookup failed after cluster became ready. Will retry next reconcile."
        continue
    fi
    CLUSTER_ID=$(echo "${CLUSTER_JSON}" | jq -r '.id // empty')
    API_URL=$(echo "${CLUSTER_JSON}" | jq -r '.api.url // empty')
    ACTUAL_VERSION=$(echo "${CLUSTER_JSON}" | jq -r '.openshift_version // empty')
    VERSION_LABEL=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)

    if [[ -z "${CLUSTER_ID}" || -z "${API_URL}" || -z "${ACTUAL_VERSION}" ]]; then
        log "WARNING: Incomplete cluster data for ${NAME} (id=${CLUSTER_ID}, api=${API_URL}, version=${ACTUAL_VERSION}). Will retry."
        continue
    fi

    register_lease "${NAME}" "available" "${CLUSTER_ID}" "${TYPE}" "${ENV}" "${REGION}" "${VERSION_LABEL}" "${API_URL}" "${ACTUAL_VERSION}"
    log "Registered ${NAME} (${CLUSTER_ID}) in lease inventory"

    # Set expiration to +28 days to prevent OCM auto-deletion
    CLUSTER_HREF=$(echo "${CLUSTER_JSON}" | jq -r '.href // empty')
    if [[ -n "${CLUSTER_HREF}" ]]; then
        EXPIRATION=$(date -u -d "+28 days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+28d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
        if [[ -n "${EXPIRATION}" ]]; then
            if echo "{\"expiration_timestamp\": \"${EXPIRATION}\"}" | ocm patch "${CLUSTER_HREF}" 2>/dev/null; then
                log "Set expiration for ${NAME} to ${EXPIRATION}"
            else
                log "WARNING: Failed to set expiration for ${NAME} (org may need bypass_max_expiration capability)"
            fi
        fi
    fi
done < <(echo "${DESIRED_NAMES}")

# ---------------------------------------------------------------
# Phase 4: Health check existing clusters
# ---------------------------------------------------------------
log "Phase 4: Health checking existing clusters"

# Re-read actual state (may have changed from provisioning)
ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
ACTUAL_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')

HEALTHY=0
UNHEALTHY=0
RECOVERED=0

for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
    CM=$(echo "${ACTUAL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    STATUS=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    HOLDER=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    ACQUIRED_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')

    # Stale lease recovery (per-operator and legacy)
    if [[ "${STATUS}" == "in-use" ]]; then
        OPERATORS_ANNOTATION=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/operators"] // ""')

        if [[ -n "${OPERATORS_ANNOTATION}" ]]; then
            # Per-operator mode: check each operator's timestamp for staleness
            STALE_OPS=""
            LIVE_OPS=""
            IFS=',' read -ra OP_LIST <<< "${OPERATORS_ANNOTATION}"
            for op_entry in "${OP_LIST[@]}"; do
                [[ -z "${op_entry}" ]] && continue
                OP_NAME=$(echo "${op_entry}" | cut -d: -f1)
                OP_EPOCH=$(echo "${op_entry}" | cut -d: -f2)
                OP_AGE=$(( NOW_EPOCH - OP_EPOCH ))
                if [[ ${OP_AGE} -gt ${STALE_THRESHOLD} ]]; then
                    OP_HOURS=$(( OP_AGE / 3600 ))
                    log "STALE OPERATOR: ${OP_NAME} on ${CM_NAME} for ${OP_HOURS}h"
                    STALE_OPS="${STALE_OPS:+${STALE_OPS},}${OP_NAME}"
                else
                    LIVE_OPS="${LIVE_OPS:+${LIVE_OPS},}${op_entry}"
                fi
            done

            if [[ -n "${STALE_OPS}" ]]; then
                if [[ -z "${LIVE_OPS}" ]]; then
                    # All operators stale, release the whole cluster
                    if ! dry_run_guard "Would release all stale operators on ${CM_NAME}"; then
                        RECOVERED_CM=$(echo "${CM}" | jq '
                            .metadata.labels["rosa-cluster-lease/status"] = "available" |
                            .metadata.annotations["rosa-cluster-lease/operators"] = "" |
                            .metadata.annotations["rosa-cluster-lease/holder"] = "" |
                            .metadata.annotations["rosa-cluster-lease/build-id"] = "" |
                            .metadata.annotations["rosa-cluster-lease/released-at"] = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" |
                            .metadata.annotations["rosa-cluster-lease/recovered-by"] = "controller"
                        ')
                        echo "${RECOVERED_CM}" | lease_oc replace -n "${LEASE_NAMESPACE}" -f - || true
                    fi
                    echo "RECOVERED: ${CM_NAME} (all operators stale: ${STALE_OPS})" >> "${REPORT}"
                else
                    # Some operators stale, remove just those
                    if ! dry_run_guard "Would remove stale operators ${STALE_OPS} from ${CM_NAME}"; then
                        RECOVERED_CM=$(echo "${CM}" | jq '
                            .metadata.annotations["rosa-cluster-lease/operators"] = "'"${LIVE_OPS}"'" |
                            .metadata.annotations["rosa-cluster-lease/released-at"] = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" |
                            .metadata.annotations["rosa-cluster-lease/recovered-by"] = "controller"
                        ')
                        echo "${RECOVERED_CM}" | lease_oc replace -n "${LEASE_NAMESPACE}" -f - || true
                    fi
                    echo "RECOVERED: ${CM_NAME} (stale operators: ${STALE_OPS}, remaining: ${LIVE_OPS})" >> "${REPORT}"
                fi
                RECOVERED=$((RECOVERED + 1))
                continue
            fi
        elif [[ -n "${ACQUIRED_AT}" ]]; then
            # Legacy exclusive mode: check acquired-at timestamp
            ACQUIRED_EPOCH=$(date -d "${ACQUIRED_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ACQUIRED_AT}" +%s 2>/dev/null || echo "0")
            LEASE_AGE=$(( NOW_EPOCH - ACQUIRED_EPOCH ))

            if [[ ${LEASE_AGE} -gt ${STALE_THRESHOLD} ]]; then
                LEASE_HOURS=$(( LEASE_AGE / 3600 ))
                log "STALE LEASE: ${CM_NAME} held by ${HOLDER} for ${LEASE_HOURS}h"

                if ! dry_run_guard "Would release stale lease on ${CM_NAME}"; then
                    lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                        "metadata": {
                            "labels": { "rosa-cluster-lease/status": "available" },
                            "annotations": {
                                "rosa-cluster-lease/holder": "",
                                "rosa-cluster-lease/build-id": "",
                                "rosa-cluster-lease/released-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
                                "rosa-cluster-lease/recovered-by": "controller"
                            }
                        }
                    }' || true
                fi
                RECOVERED=$((RECOVERED + 1))
                echo "RECOVERED: ${CM_NAME} (stale ${LEASE_HOURS}h)" >> "${REPORT}"
                continue
            fi
        fi
    fi

    # Check OCM health for in-use clusters (report only, no action while job is running)
    if [[ "${STATUS}" == "in-use" ]]; then
        ocm_check_cluster "${CLUSTER_ID}" "$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')"
        if [[ "${OCM_CHECK_RESULT}" == "unreachable" ]]; then
            echo "IN-USE: ${CM_NAME} by ${HOLDER} (OCM unreachable)" >> "${REPORT}"
        elif [[ "${OCM_CHECK_RESULT}" == "not-found" || "${OCM_CHECK_STATUS}" != "ready" ]]; then
            log "WARNING: ${CM_NAME} in-use by ${HOLDER} but OCM status is ${OCM_CHECK_RESULT}/${OCM_CHECK_STATUS}"
            UNHEALTHY=$((UNHEALTHY + 1))
            echo "IN-USE WARNING: ${CM_NAME} by ${HOLDER} (OCM: ${OCM_CHECK_STATUS:-${OCM_CHECK_RESULT}})" >> "${REPORT}"
        else
            HEALTHY=$((HEALTHY + 1))
            echo "IN-USE: ${CM_NAME} by ${HOLDER} (OCM: ${OCM_CHECK_STATUS})" >> "${REPORT}"
        fi
        continue
    fi

    # Reconcile provisioning clusters from their current OCM state
    if [[ "${STATUS}" == "provisioning" ]]; then
        ocm_check_cluster "${CLUSTER_ID}" "$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')"
        if [[ "${OCM_CHECK_RESULT}" == "unreachable" ]]; then
            log "WARNING: ${CM_NAME} OCM unreachable, skipping provisioning check"
            echo "SKIPPED: ${CM_NAME} (OCM unreachable)" >> "${REPORT}"
        elif [[ "${OCM_CHECK_RESULT}" == "not-found" ]]; then
            log "STALE PROVISIONING: ${CM_NAME} no longer exists in OCM, removing ConfigMap"
            if dry_run_guard "Would delete stale provisioning ConfigMap ${CM_NAME}"; then
                echo "DRY RUN: ${CM_NAME} (stale provisioning, would remove)" >> "${REPORT}"
            elif lease_oc delete configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}"; then
                echo "STALE PROVISIONING: ${CM_NAME} (removed, will reprovision next run)" >> "${REPORT}"
            else
                log "WARNING: Failed to delete stale ConfigMap ${CM_NAME}"
                echo "STALE PROVISIONING: ${CM_NAME} (delete failed)" >> "${REPORT}"
            fi
            UNHEALTHY=$((UNHEALTHY + 1))
        elif [[ "${OCM_CHECK_STATUS}" == "ready" ]]; then
            API_URL=$(echo "${OCM_CHECK_RESPONSE}" | jq -r '.api.url // empty')
            ACTUAL_VERSION=$(echo "${OCM_CHECK_RESPONSE}" | jq -r '.openshift_version // empty')
            VERSION_LABEL=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)
            if [[ -z "${API_URL}" || -z "${ACTUAL_VERSION}" ]]; then
                log "WARNING: Incomplete cluster data for ${CM_NAME}, leaving provisioning for retry"
                echo "SKIPPED: ${CM_NAME} (ready, incomplete cluster data)" >> "${REPORT}"
                continue
            fi
            if dry_run_guard "Would mark ${CM_NAME} as available"; then
                echo "DRY RUN: ${CM_NAME} (ready, would mark available)" >> "${REPORT}"
            elif lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p "$(jq -n \
                --arg api_url "${API_URL}" --arg version "${ACTUAL_VERSION}" --arg version_label "${VERSION_LABEL}" '{
                    metadata: {labels: {"rosa-cluster-lease/status": "available", "rosa-cluster-lease/version": $version_label}},
                    data: {"api-url": $api_url, version: $version}
                }')"; then
                log "PROVISIONED: ${CM_NAME} is ready, restored to available"
                echo "PROVISIONED: ${CM_NAME} (available)" >> "${REPORT}"
            else
                log "WARNING: Failed to mark ${CM_NAME} as available"
                echo "SKIPPED: ${CM_NAME} (ready, patch failed)" >> "${REPORT}"
                continue
            fi
            HEALTHY=$((HEALTHY + 1))
        elif [[ "${OCM_CHECK_STATUS}" == "error" || "${OCM_CHECK_STATUS}" == "uninstalling" ]]; then
            log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_CHECK_STATUS}"
            if dry_run_guard "Would mark ${CM_NAME} as error"; then
                echo "DRY RUN: ${CM_NAME} (OCM: ${OCM_CHECK_STATUS}, would mark error)" >> "${REPORT}"
            elif lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p "$(jq -n \
                --arg reason "OCM status: ${OCM_CHECK_STATUS}" --arg error_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
                    metadata: {
                        labels: {"rosa-cluster-lease/status": "error"},
                        annotations: {"rosa-cluster-lease/error-reason": $reason, "rosa-cluster-lease/error-at": $error_at}
                    }
                }')"; then
                echo "UNHEALTHY: ${CM_NAME} (OCM: ${OCM_CHECK_STATUS})" >> "${REPORT}"
            else
                log "WARNING: Failed to mark ${CM_NAME} as error"
                echo "UNHEALTHY: ${CM_NAME} (OCM: ${OCM_CHECK_STATUS}, patch failed)" >> "${REPORT}"
            fi
            UNHEALTHY=$((UNHEALTHY + 1))
        elif [[ "${OCM_CHECK_STATUS}" == "pending" || "${OCM_CHECK_STATUS}" == "installing" || "${OCM_CHECK_STATUS}" == "waiting" ]]; then
            echo "PROVISIONING: ${CM_NAME} (OCM: ${OCM_CHECK_STATUS})" >> "${REPORT}"
            HEALTHY=$((HEALTHY + 1))
        else
            log "WARNING: ${CM_NAME} has unexpected OCM state ${OCM_CHECK_STATUS}, leaving provisioning for retry"
            echo "SKIPPED: ${CM_NAME} (unexpected OCM state: ${OCM_CHECK_STATUS})" >> "${REPORT}"
        fi
        continue
    fi

    # Check if maintenance (upgrade) has completed
    if [[ "${STATUS}" == "maintenance" ]]; then
        UPGRADE_TARGET=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/upgrade-target"] // ""')
        ocm_check_cluster "${CLUSTER_ID}" "$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')"
        CURRENT_VERSION=$(echo "${OCM_CHECK_RESPONSE}" | jq -r '.openshift_version // ""' 2>/dev/null || true)

        if [[ "${OCM_CHECK_STATUS}" == "ready" && -n "${UPGRADE_TARGET}" && "${CURRENT_VERSION}" == "${UPGRADE_TARGET}" ]]; then
            log "UPGRADE COMPLETE: ${CM_NAME} upgraded to ${CURRENT_VERSION}"
            VERSION_LABEL=$(echo "${CURRENT_VERSION}" | cut -d. -f1,2)
            if ! dry_run_guard "Would restore ${CM_NAME} to available"; then
                lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-cluster-lease/status": "available", "rosa-cluster-lease/version": "'"${VERSION_LABEL}"'" },
                        "annotations": { "rosa-cluster-lease/upgrade-target": "" }
                    },
                    "data": { "version": "'"${CURRENT_VERSION}"'" }
                }' || true
            fi
            echo "UPGRADE COMPLETE: ${CM_NAME} -> ${CURRENT_VERSION}" >> "${REPORT}"
        elif [[ "${OCM_CHECK_STATUS}" == "ready" && -z "${UPGRADE_TARGET}" ]]; then
            log "REFRESH RECOVERY: ${CM_NAME} is ready in OCM but stuck in maintenance (no upgrade target), restoring to available"
            CURRENT_VERSION=$(echo "${OCM_CHECK_RESPONSE}" | jq -r '.openshift_version // ""' 2>/dev/null || true)
            VERSION_LABEL=$(echo "${CURRENT_VERSION}" | cut -d. -f1,2)
            if ! dry_run_guard "Would restore ${CM_NAME} to available"; then
                if lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-cluster-lease/status": "available", "rosa-cluster-lease/version": "'"${VERSION_LABEL}"'" }
                    },
                    "data": { "version": "'"${CURRENT_VERSION}"'" }
                }'; then
                    echo "REFRESH RECOVERY: ${CM_NAME} (restored to available)" >> "${REPORT}"
                else
                    log "ERROR: Failed to restore ${CM_NAME} to available after refresh recovery"
                fi
            else
                echo "REFRESH RECOVERY: ${CM_NAME} (would restore to available, dry-run)" >> "${REPORT}"
            fi
        fi
        HEALTHY=$((HEALTHY + 1))
        continue
    fi

    # Check OCM cluster status (available/error clusters)
    ocm_check_cluster "${CLUSTER_ID}" "$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')"

    if [[ "${OCM_CHECK_RESULT}" == "unreachable" ]]; then
        log "WARNING: ${CM_NAME} OCM unreachable (connectivity issue), skipping health check"
        echo "SKIPPED: ${CM_NAME} (OCM unreachable)" >> "${REPORT}"
        continue
    fi

    if [[ "${OCM_CHECK_RESULT}" == "not-found" ]]; then
        log "UNHEALTHY: ${CM_NAME} no longer exists in OCM (deleted or expired)"
        if [[ "${STATUS}" != "error" ]] && ! dry_run_guard "Would mark ${CM_NAME} as error"; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "Cluster deleted from OCM", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        echo "UNHEALTHY: ${CM_NAME} (deleted from OCM)" >> "${REPORT}"
        continue
    fi

    if [[ "${OCM_CHECK_STATUS}" != "ready" ]]; then
        log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_CHECK_STATUS}"
        if [[ "${STATUS}" != "error" ]] && ! dry_run_guard "Would mark ${CM_NAME} as error"; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "OCM status: '"${OCM_CHECK_STATUS}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }' || true
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        echo "UNHEALTHY: ${CM_NAME} (OCM: ${OCM_CHECK_STATUS})" >> "${REPORT}"
        continue
    fi

    # RBAC smoke test: verify dedicated-admins group permissions are propagated.
    # This catches broken rbac-permissions-operator before clusters are leased,
    # preventing e2e test timeouts waiting for permissions that never arrive.
    RBAC_KUBECONFIG=$(mktemp)
    trap 'rm -f "${RBAC_KUBECONFIG}"; ocm_auth_cleanup' EXIT
    RBAC_CHECK_FAILED=false
    if ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null \
        | jq -r '.kubeconfig // empty' > "${RBAC_KUBECONFIG}" 2>/dev/null \
        && [[ -s "${RBAC_KUBECONFIG}" ]]; then
        RBAC_RESULT=$(oc auth can-i create configmaps \
            --as=dedicated-admin-check --as-group=dedicated-admins \
            -n dedicated-admin \
            --request-timeout=30s \
            --kubeconfig="${RBAC_KUBECONFIG}" 2>&1) || true
        if [[ "${RBAC_RESULT}" == "no" ]]; then
            log "UNHEALTHY: ${CM_NAME} RBAC check failed - dedicated-admins cannot create configmaps"
            RBAC_CHECK_FAILED=true
        elif [[ "${RBAC_RESULT}" != "yes" ]]; then
            log "WARNING: ${CM_NAME} RBAC check inconclusive (connectivity issue?), skipping"
        fi
    else
        log "WARNING: ${CM_NAME} could not retrieve cluster kubeconfig for RBAC check, skipping"
    fi
    rm -f "${RBAC_KUBECONFIG}"
    trap 'ocm_auth_cleanup' EXIT

    if [[ "${RBAC_CHECK_FAILED}" == "true" ]]; then
        if [[ "${STATUS}" != "error" ]] && ! dry_run_guard "Would mark ${CM_NAME} as error (RBAC)"; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "RBAC: dedicated-admins permissions not functional", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }'
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        echo "UNHEALTHY: ${CM_NAME} (RBAC: dedicated-admins broken)" >> "${REPORT}"
        continue
    fi

    # PKO health check: detect ClusterPackages stuck on "refusing adoption"
    # and repair CRD ownership labels so PKO can re-adopt.
    PKO_KUBECONFIG=$(mktemp)
    trap 'rm -f "${PKO_KUBECONFIG}"; ocm_auth_cleanup' EXIT
    PKO_CHECK_FAILED=false
    if ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null \
        | jq -r '.kubeconfig // empty' > "${PKO_KUBECONFIG}" 2>/dev/null \
        && [[ -s "${PKO_KUBECONFIG}" ]]; then
        STUCK_PKGS=$(oc get clusterpackage -l "hive.openshift.io/managed=true" \
            -o json --kubeconfig="${PKO_KUBECONFIG}" 2>/dev/null \
            | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Progressing" and (.message // "" | contains("refusing adoption")))) | .metadata.name + "|" + (.status.conditions[] | select(.type=="Progressing") | .message)' 2>/dev/null) || true
        if [[ -n "${STUCK_PKGS}" ]]; then
            while IFS='|' read -r PKG_NAME PKG_MSG; do
                [[ -z "${PKG_NAME}" ]] && continue
                # Parse CRD name from message format: "object /<crd-name> kind:CustomResourceDefinition"
                CRD_NAME=$(echo "${PKG_MSG}" | sed -n 's|.*object /\([^ ]*\) kind:CustomResourceDefinition.*|\1|p')
                if [[ -z "${CRD_NAME}" ]]; then
                    log "WARNING: ${CM_NAME} could not parse CRD name from PKO error: ${PKG_MSG}"
                    continue
                fi
                # Check the CRD's instance label
                CRD_INSTANCE=$(oc get crd "${CRD_NAME}" \
                    -o jsonpath='{.metadata.labels.package-operator\.run/instance}' \
                    --kubeconfig="${PKO_KUBECONFIG}" 2>/dev/null || true)
                if [[ "${CRD_INSTANCE}" != "${PKG_NAME}" ]]; then
                    log "Repairing CRD ${CRD_NAME} ownership: instance=${CRD_INSTANCE:-<empty>} -> ${PKG_NAME}"
                    if dry_run_guard "Would repair CRD ${CRD_NAME} ownership for ${PKG_NAME}"; then continue; fi
                    if ! oc patch crd "${CRD_NAME}" --type merge \
                        -p '{"metadata":{"ownerReferences":[],"labels":{"package-operator.run/instance":"'"${PKG_NAME}"'"}}}' \
                        --kubeconfig="${PKO_KUBECONFIG}" 2>/dev/null; then
                        log "UNHEALTHY: ${CM_NAME} PKO CRD repair failed for ${CRD_NAME}"
                        PKO_CHECK_FAILED=true
                    else
                        log "Repaired CRD ${CRD_NAME} for ClusterPackage ${PKG_NAME}"
                    fi
                fi
            done <<< "${STUCK_PKGS}"
        fi

        # ClusterPackage Available check: detect any ClusterPackage with Available != True.
        # This catches degraded CPs that the "refusing adoption" check above does not cover,
        # matching the health check's ClusterPackage backstop stamp format.
        if [[ "${PKO_CHECK_FAILED}" != "true" ]]; then
            DEGRADED_CP=$(oc get clusterpackage -l "hive.openshift.io/managed=true" \
                -o json --kubeconfig="${PKO_KUBECONFIG}" 2>/dev/null \
                | jq -r '.items[] |
                    select(any(.status.conditions[]?;
                        .type == "Available" and .status == "True") | not) |
                    .metadata.name' 2>/dev/null | head -n1) || true
            if [[ -n "${DEGRADED_CP}" ]]; then
                log "UNHEALTHY: ${CM_NAME} ClusterPackage ${DEGRADED_CP} has Available != True"
                if [[ "${STATUS}" != "error" ]] && ! dry_run_guard "Would mark ${CM_NAME} as error (ClusterPackage degraded)"; then
                    lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                        "metadata": {
                            "labels": { "rosa-cluster-lease/status": "error" },
                            "annotations": { "rosa-cluster-lease/error-reason": "ClusterPackage: degraded:'"${DEGRADED_CP}"'", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                        }
                    }'
                fi
                rm -f "${PKO_KUBECONFIG}"
                trap 'ocm_auth_cleanup' EXIT
                UNHEALTHY=$((UNHEALTHY + 1))
                echo "UNHEALTHY: ${CM_NAME} (ClusterPackage: degraded:${DEGRADED_CP})" >> "${REPORT}"
                continue
            fi
        fi
    else
        log "WARNING: ${CM_NAME} could not retrieve cluster kubeconfig for PKO check, skipping"
    fi
    rm -f "${PKO_KUBECONFIG}"
    trap 'ocm_auth_cleanup' EXIT

    if [[ "${PKO_CHECK_FAILED}" == "true" ]]; then
        if [[ "${STATUS}" != "error" ]] && ! dry_run_guard "Would mark ${CM_NAME} as error (PKO)"; then
            lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": {
                    "labels": { "rosa-cluster-lease/status": "error" },
                    "annotations": { "rosa-cluster-lease/error-reason": "PKO: CRD ownership repair failed", "rosa-cluster-lease/error-at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" }
                }
            }'
        fi
        UNHEALTHY=$((UNHEALTHY + 1))
        echo "UNHEALTHY: ${CM_NAME} (PKO: CRD ownership repair failed)" >> "${REPORT}"
        continue
    fi

    # Restore clusters that recovered from error
    if [[ "${STATUS}" == "error" ]]; then
        ERROR_REASON=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/error-reason"] // ""')
        if [[ "${ERROR_REASON}" == ClusterPackage:* ]]; then
            log "SKIPPING RESTORE: ${CM_NAME} has health-check ClusterPackage error-reason, deferring to health check for recovery"
            echo "SKIPPED RESTORE: ${CM_NAME} (error-reason: ${ERROR_REASON})" >> "${REPORT}"
            UNHEALTHY=$((UNHEALTHY + 1))
            continue
        else
            log "RESTORED: ${CM_NAME} is healthy again"
            if ! dry_run_guard "Would restore ${CM_NAME} to available"; then
                lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                    "metadata": {
                        "labels": { "rosa-cluster-lease/status": "available" },
                        "annotations": { "rosa-cluster-lease/error-reason": "", "rosa-cluster-lease/error-at": "" }
                    }
                }' || true
            fi
            echo "RESTORED: ${CM_NAME}" >> "${REPORT}"
        fi
    fi

    HEALTHY=$((HEALTHY + 1))
done

# ---------------------------------------------------------------
# Phase 4.5: Cluster Refresh (age-based rotation)
# ---------------------------------------------------------------
if [[ "${MAX_CLUSTER_AGE_HOURS}" -eq 0 ]]; then
    log "Phase 4.5: Cluster refresh skipped (MAX_CLUSTER_AGE_HOURS=0)"
else
    log "Phase 4.5: Checking for clusters to refresh (max age: ${MAX_CLUSTER_AGE_HOURS}h)"

    CURRENT_DAY=$(date +%u)
    if [[ "${CURRENT_DAY}" != "${REFRESH_DAY}" ]]; then
        log "Phase 4.5: Skipping refresh (today=${CURRENT_DAY}, refresh day=${REFRESH_DAY})"
    else
        log "Phase 4.5: Refresh day matched (day=${CURRENT_DAY}), scanning available clusters"

        REFRESH_COUNT=0
        REFRESH_REMAINING=0

        AVAILABLE_CMS=$(lease_oc get configmaps -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true,rosa-cluster-lease/status=available" -o json 2>/dev/null || echo '{"items":[]}')
        AVAILABLE_COUNT=$(echo "${AVAILABLE_CMS}" | jq '.items | length')

        for i in $(seq 0 $((AVAILABLE_COUNT - 1))); do
            CM=$(echo "${AVAILABLE_CMS}" | jq ".items[${i}]")
            CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
            CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
            REGISTERED_AT=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/registered-at"] // ""')

            if [[ -z "${REGISTERED_AT}" ]]; then
                log "WARNING: ${CM_NAME} has no registered-at annotation, skipping refresh check"
                continue
            fi

            REGISTERED_EPOCH=$(date -d "${REGISTERED_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${REGISTERED_AT}" +%s 2>/dev/null || true)
            if [[ -z "${REGISTERED_EPOCH}" || "${REGISTERED_EPOCH}" == "0" ]]; then
                log "WARNING: ${CM_NAME} has unparseable registered-at '${REGISTERED_AT}', skipping refresh check"
                continue
            fi
            AGE_SECONDS=$(( NOW_EPOCH - REGISTERED_EPOCH ))
            AGE_HOURS=$(( AGE_SECONDS / 3600 ))

            if [[ ${AGE_HOURS} -gt ${MAX_CLUSTER_AGE_HOURS} ]]; then
                if [[ ${REFRESH_COUNT} -ge ${MAX_REFRESH_PER_RUN} ]]; then
                    log "Stagger limit reached (${MAX_REFRESH_PER_RUN}), deferring remaining refreshes to next run"
                    REFRESH_REMAINING=$((REFRESH_REMAINING + 1))
                    continue
                fi

                log "REFRESH: Cluster ${CM_NAME} is ${AGE_HOURS}h old (max: ${MAX_CLUSTER_AGE_HOURS}), marking for replacement"
                echo "REFRESH: ${CM_NAME} (age: ${AGE_HOURS}h, max: ${MAX_CLUSTER_AGE_HOURS}h)" >> "${REPORT}"

                if dry_run_guard "Would refresh ${CM_NAME}"; then
                    REFRESH_COUNT=$((REFRESH_COUNT + 1))
                    continue
                fi

                CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
                CLUSTER_TYPE=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/type"] // "classic-sts"')
                ocm_ensure_env "${CLUSTER_OCM_ENV}"

                lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                    "metadata": { "labels": { "rosa-cluster-lease/status": "maintenance" } }
                }'
                if ! delete_cluster "${CLUSTER_ID}" "${CLUSTER_TYPE}"; then
                    log "WARNING: delete_cluster failed for ${CM_NAME}, restoring to available"
                    if ! lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                        "metadata": { "labels": { "rosa-cluster-lease/status": "available" } }
                    }'; then
                        log "ERROR: Failed to restore ${CM_NAME} to available after delete failure"
                    fi
                    continue
                fi
                lease_oc delete configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}"

                REFRESH_COUNT=$((REFRESH_COUNT + 1))
                log "Deleted ${CM_NAME} for refresh. Replacement will be provisioned on next reconcile."
            fi
        done

        log "Refreshed ${REFRESH_COUNT} clusters, ${REFRESH_REMAINING} remaining for next run"
    fi
fi

# ---------------------------------------------------------------
# Phase 5: Replace unhealthy clusters
# ---------------------------------------------------------------
log "Phase 5: Checking for clusters to replace"

ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true,rosa-cluster-lease/status=error" -o json 2>/dev/null || echo '{"items":[]}')
ERROR_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')

for i in $(seq 0 $((ERROR_COUNT - 1))); do
    CM=$(echo "${ACTUAL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    ERROR_AT=$(echo "${CM}" | jq -r '(.metadata.annotations["rosa-cluster-lease/error-at"] | select(. != "")) // .metadata.creationTimestamp // ""')

    if [[ -z "${ERROR_AT}" ]]; then
        continue
    fi

    ERROR_EPOCH=$(date -d "${ERROR_AT}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ERROR_AT}" +%s 2>/dev/null || echo "0")
    ERROR_AGE=$(( NOW_EPOCH - ERROR_EPOCH ))

    if [[ ${ERROR_AGE} -lt ${ERROR_THRESHOLD} ]]; then
        log "${CM_NAME}: in error for $((ERROR_AGE / 60))m, threshold is $((ERROR_THRESHOLD / 60))m. Waiting."
        continue
    fi

    log "REPLACE: ${CM_NAME} has been in error for $((ERROR_AGE / 3600))h, deleting"
    echo "REPLACE: ${CM_NAME} (error for $((ERROR_AGE / 3600))h)" >> "${REPORT}"

    if dry_run_guard "Would delete and replace ${CM_NAME}"; then
        continue
    fi

    CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
    CLUSTER_TYPE=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/type"] // "classic-sts"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    ocm_check_cluster "${CLUSTER_ID}" "${CLUSTER_OCM_ENV}"
    if [[ "${OCM_CHECK_RESULT}" == "not-found" ]]; then
        log "${CM_NAME}: cluster already deleted from OCM, skipping delete_cluster"
    else
        if ! delete_cluster "${CLUSTER_ID}" "${CLUSTER_TYPE}"; then
            log "WARNING: delete_cluster failed for ${CM_NAME}, preserving ConfigMap"
            continue
        fi
    fi

    # Remove the ConfigMap (next reconcile will provision a replacement)
    lease_oc delete configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}"
    log "Deleted ${CM_NAME}. Replacement will be provisioned on next reconcile."
done

# ---------------------------------------------------------------
# Phase 6: Version upgrades
# ---------------------------------------------------------------
log "Phase 6: Checking for version upgrades"

while IFS= read -r cluster_json; do
    [[ -z "${cluster_json}" ]] && continue

    NAME=$(echo "${cluster_json}" | jq -r '.name')
    DESIRED_VERSION=$(echo "${cluster_json}" | jq -r '.version // ""')
    CHANNEL=$(echo "${cluster_json}" | jq -r '.["channel-group"] // "stable"')

    [[ -z "${DESIRED_VERSION}" ]] && continue

    # Get actual cluster info
    ACTUAL_CM=$(lease_oc get configmap "${NAME}" -n "${LEASE_NAMESPACE}" -o json 2>/dev/null || echo "")
    [[ -z "${ACTUAL_CM}" ]] && continue

    ACTUAL_VERSION=$(echo "${ACTUAL_CM}" | jq -r '.data.version // ""')
    STATUS=$(echo "${ACTUAL_CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    CLUSTER_ID=$(echo "${ACTUAL_CM}" | jq -r '.data["cluster-id"]')

    [[ -z "${ACTUAL_VERSION}" ]] && continue

    # Only upgrade available clusters
    if [[ "${STATUS}" != "available" ]]; then
        continue
    fi

    # Check if actual version is older than desired
    ACTUAL_MINOR=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)
    if [[ "${ACTUAL_MINOR}" == "${DESIRED_VERSION}" ]]; then
        continue
    fi

    # Resolve target version
    CLUSTER_OCM_ENV=$(echo "${ACTUAL_CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    CLUSTER_TYPE=$(echo "${ACTUAL_CM}" | jq -r '.metadata.labels["rosa-cluster-lease/type"] // "classic-sts"')
    TARGET_VERSION=$(list_upgrades "${CLUSTER_ID}" "${CLUSTER_TYPE}" "${DESIRED_VERSION}")

    if [[ -z "${TARGET_VERSION}" ]]; then
        continue
    fi

    log "UPGRADE: ${NAME} from ${ACTUAL_VERSION} to ${TARGET_VERSION}"
    echo "UPGRADE: ${NAME} ${ACTUAL_VERSION} -> ${TARGET_VERSION}" >> "${REPORT}"

    if dry_run_guard "Would upgrade ${NAME} to ${TARGET_VERSION}"; then
        continue
    fi

    # Mark as maintenance during upgrade
    lease_oc patch configmap "${NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
        "metadata": {
            "labels": { "rosa-cluster-lease/status": "maintenance" },
            "annotations": { "rosa-cluster-lease/upgrade-target": "'"${TARGET_VERSION}"'" }
        }
    }' || true

    schedule_upgrade "${CLUSTER_ID}" "${CLUSTER_TYPE}" "${TARGET_VERSION}" 2>/dev/null || {
            log "WARNING: Failed to schedule upgrade for ${NAME}"
            lease_oc patch configmap "${NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
                "metadata": { "labels": { "rosa-cluster-lease/status": "available" } }
            }' || true
        }
done < <(echo "${DESIRED_NAMES}")

# ---------------------------------------------------------------
# Phase 7: Decommission unwanted clusters
# ---------------------------------------------------------------
log "Phase 7: Checking for clusters to decommission"

ACTUAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
ACTUAL_COUNT=$(echo "${ACTUAL_CMS}" | jq '.items | length')

for i in $(seq 0 $((ACTUAL_COUNT - 1))); do
    CM_NAME=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].metadata.name")
    STATUS=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].metadata.labels[\"rosa-cluster-lease/status\"]")

    # Check if this cluster is still desired
    IS_DESIRED=$(echo "${DESIRED_NAMES}" | jq -r "select(.name == \"${CM_NAME}\") | .name" 2>/dev/null || true)
    if [[ -n "${IS_DESIRED}" ]]; then
        continue
    fi

    # Only decommission available clusters (wait for in-use to finish)
    if [[ "${STATUS}" != "available" && "${STATUS}" != "error" ]]; then
        log "${CM_NAME}: not in desired state but status is ${STATUS}, waiting"
        continue
    fi

    CLUSTER_ID=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].data[\"cluster-id\"]")
    log "DECOMMISSION: ${CM_NAME} (${CLUSTER_ID}) no longer in desired state"
    echo "DECOMMISSION: ${CM_NAME}" >> "${REPORT}"

    if dry_run_guard "Would decommission ${CM_NAME}"; then
        continue
    fi

    CLUSTER_OCM_ENV=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].data[\"ocm-env\"] // \"staging\"")
    CLUSTER_TYPE=$(echo "${ACTUAL_CMS}" | jq -r ".items[${i}].metadata.labels[\"rosa-cluster-lease/type\"] // \"classic-sts\"")
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    delete_cluster "${CLUSTER_ID}" "${CLUSTER_TYPE}" || true
    lease_oc delete configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" || true
    log "Decommissioned ${CM_NAME}"
done

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo "" >> "${REPORT}"
echo "=== Cluster Inventory ===" >> "${REPORT}"
FINAL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json 2>/dev/null || echo '{"items":[]}')
FINAL_COUNT=$(echo "${FINAL_CMS}" | jq '.items | length')
for i in $(seq 0 $((FINAL_COUNT - 1))); do
    F_CM=$(echo "${FINAL_CMS}" | jq ".items[${i}]")
    F_NAME=$(echo "${F_CM}" | jq -r '.metadata.name')
    F_STATUS=$(echo "${F_CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"] // "unknown"')
    F_ENV=$(echo "${F_CM}" | jq -r '.metadata.labels["rosa-cluster-lease/env"] // ""')
    F_TYPE=$(echo "${F_CM}" | jq -r '.metadata.labels["rosa-cluster-lease/type"] // ""')
    F_OPS=$(echo "${F_CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/operators"] // ""')
    F_HOLDER=$(echo "${F_CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    F_BUILD=$(echo "${F_CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/build-id"] // ""')
    F_ACQ=$(echo "${F_CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')
    printf "  %-40s status=%-12s env=%-10s type=%s\n" "${F_NAME}" "${F_STATUS}" "${F_ENV}" "${F_TYPE}" >> "${REPORT}"
    [[ -n "${F_OPS}" ]] && echo "    operators: ${F_OPS}" >> "${REPORT}"
    [[ -n "${F_HOLDER}" ]] && echo "    holder: ${F_HOLDER} build=${F_BUILD} acquired=${F_ACQ}" >> "${REPORT}"
done

echo "" >> "${REPORT}"
echo "Summary: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${RECOVERED} recovered" >> "${REPORT}"

log "Controller reconcile complete"
cat "${REPORT}"
