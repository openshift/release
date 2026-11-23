#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


HOSTED_CP=${HOSTED_CP:-false}
BYO_OIDC=${BYO_OIDC:-false}
ENABLE_BYOVPC=${ENABLE_BYOVPC:-false}
ENABLE_SHARED_VPC=${ENABLE_SHARED_VPC:-"no"}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}
STALL_TIMEOUT=${STALL_TIMEOUT:-3600}
PROVISIONER_LAUNCH_TIMEOUT=${PROVISIONER_LAUNCH_TIMEOUT:-900}
OCM_RECONCILIATION_TIMEOUT=${OCM_RECONCILIATION_TIMEOUT:-600}
if [[ ! "${PROVISIONER_LAUNCH_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  log "ERROR: PROVISIONER_LAUNCH_TIMEOUT must be a non-negative integer, got '${PROVISIONER_LAUNCH_TIMEOUT}'. Using default 900."
  PROVISIONER_LAUNCH_TIMEOUT=900
fi
if [[ ! "${OCM_RECONCILIATION_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: OCM_RECONCILIATION_TIMEOUT must be a non-negative integer, got '${OCM_RECONCILIATION_TIMEOUT}'. Using default 600." >&2
  OCM_RECONCILIATION_TIMEOUT=600
fi
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

capture_classic_resources() {
    if [[ "${HOSTED_CP}" == "true" ]]; then
        return
    fi

    local live_resources
    local account_claim
    live_resources=$(mktemp)

    if ! timeout 30 ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/resources/live" \
        > "${live_resources}" 2>/dev/null; then
        log "Unable to retrieve live Classic cluster resources"
        rm -f "${live_resources}"
        return
    fi

    jq '.resources.cluster_deployment' "${live_resources}" \
        > "${ARTIFACT_DIR}/cluster-deployment.json" 2>/dev/null || true

    # The live-resource API returns each resource as a JSON-encoded string. Keep only
    # the AccountClaim fields needed for diagnosing AAO reconciliation. In particular,
    # do not publish role ARNs, external IDs, legal entity data, or secret references
    # in CI artifacts.
    account_claim=$(jq -r '.resources.aws_account_claim // empty' "${live_resources}" 2>/dev/null || true)
    if [[ -n "${account_claim}" ]]; then
        if jq '{
            apiVersion: .apiVersion,
            kind: .kind,
            metadata: {
                name: .metadata.name,
                namespace: .metadata.namespace,
                creationTimestamp: .metadata.creationTimestamp,
                generation: .metadata.generation
            },
            spec: {
                accountLink: .spec.accountLink,
                byoc: .spec.byoc,
                manualSTSMode: .spec.manualSTSMode,
                aws: .spec.aws
            },
            status: .status
        }' <<< "${account_claim}" > "${ARTIFACT_DIR}/aws-account-claim.json" 2>/dev/null; then
            log "Saved sanitized AWS AccountClaim to ${ARTIFACT_DIR}/aws-account-claim.json"
        else
            log "Unable to parse the AWS AccountClaim returned by the live-resource API"
            rm -f "${ARTIFACT_DIR}/aws-account-claim.json"
        fi
    else
        log "AWS AccountClaim is not available in the live Classic cluster resources"
    fi

    rm -f "${live_resources}"
}

capture_diagnostics_on_crash() {
    log "UNEXPECTED EXIT: Capturing diagnostics before crash..."
    timeout 30 rosa describe cluster -c "${CLUSTER_ID}" -o json > "${ARTIFACT_DIR}/cluster-description.json" 2>&1 || true
    timeout 60 rosa logs install -c "${CLUSTER_ID}" > "${ARTIFACT_DIR}/.install.log" 2>&1 || true
    capture_classic_resources || true
    log "Diagnostics captured to ${ARTIFACT_DIR}/"
}
trap 'capture_diagnostics_on_crash' ERR

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

retry_cmd() {
    local max_retries="${1:-3}"
    local delay="${2:-10}"
    shift 2 || shift $#
    local attempt=1
    local rc=0
    local retry_out
    retry_out=$(mktemp)
    trap 'rm -f "${retry_out}"' RETURN
    while (( attempt <= max_retries )); do
        rc=0
        "$@" > "${retry_out}" && { cat "${retry_out}"; return 0; } || rc=$?
        if (( attempt == max_retries )); then
            log "Command failed after ${max_retries} attempts: $*" >&2
            return ${rc}
        fi
        log "Attempt ${attempt}/${max_retries} failed (exit ${rc}), retrying in ${delay}s..." >&2
        sleep "${delay}"
        delay=$(( delay * 2 ))
        attempt=$(( attempt + 1 ))
    done
    return ${rc}
}

# DNS error chronology
#
# When a DNS failure shows up while polling the install log, the step keeps a bounded,
# timestamped snapshot of the log as it looked at that moment, together with a DNS probe
# taken from this CI pod. Otherwise an install log reaches the artifacts only when the
# step gives up or hits its crash trap: that copy may no longer report the earlier error,
# and a run that ends successfully keeps no install log at all. The snapshots keep that
# chronology.
#
# Everything in this chronology capture is bounded and best effort: it ignores its own
# failures, adds one timeout-bounded DNS probe and bounded local text processing to a
# poll, leaves the step's exit status and its readiness and failure criteria untouched,
# reads no credentials and makes no cloud API calls.
#
# These artifacts are published publicly, so a snapshot keeps only the DNS error lines
# themselves, never a general excerpt of the install log, and every line goes through
# the redaction filters below first.
DNS_ERROR_PATTERN="no such host|dial tcp: lookup"
DNS_MAX_OBSERVATIONS=3
DNS_MAX_ERROR_LINES=20
DNS_MAX_ERROR_BYTES=8192
dns_observation_count=0
dns_errors_observed="no"
dns_first_observed_at=""
dns_errors_seen_file=""
dns_limit_logged="no"

# Keep account identifiers out of public artifacts, as the rest of this step does.
# Also drop the ANSI sequences this step's own log() writes, which reach the install-log
# output through retry_cmd.
mask_sensitive_output() {
    local -a filters=(-e 's/\x1b\[[0-9;]*m//g')
    if [[ -n "${AWS_ACCOUNT_ID:-}" ]]; then
        filters+=(-e "s/${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID_MASK:-"***"}/g")
    fi
    if [[ -n "${SHARED_VPC_AWS_ACCOUNT_ID:-}" ]]; then
        filters+=(-e "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK:-"***"}/g")
    fi
    sed "${filters[@]}"
}

# Keep resolver infrastructure out of these public artifacts.
#
# Names under the Kubernetes internal zone only ever identify infrastructure internals,
# so both filters below generalise them.
redact_internal_names() {
    sed -E -e 's/[A-Za-z0-9_.-]*\.(svc\.)?cluster\.local\.?/[internal name redacted]/g'
}

# dig prints the resolver it used, and the endpoint it could not reach, in its own
# comment lines (";; SERVER:", ";; communications error to ..."). That address is the
# DNS service of the CI build farm, not information about the cluster under test.
#
# Record data is left untouched: dig's answer and authority records do not start with
# ';;', so the records that make the probe worth reading survive this filter. An IPv6
# literal is recognised bracketed or bare; a bare one is matched only in a form a clock
# time cannot take, so values such as ";; WHEN:" are left alone.
redact_resolver_addresses() {
    sed -E \
        -e 's/^;; SERVER:.*/;; SERVER: [resolver address redacted]/' \
        -e 's/^;; (communications error to|Connection to) .*/;; \1 [resolver address redacted]/' \
        -e '/^;;/ s/\[?([0-9]{1,3}\.){3}[0-9]{1,3}\]?(:[0-9]+)?/[address redacted]/g' \
        -e '/^;;/ s/\[[0-9A-Fa-f]*(:[0-9A-Fa-f]*)+(%[A-Za-z0-9._-]+)?\](:[0-9]+)?/[address redacted]/g' \
        -e '/^;;/ s/[0-9A-Fa-f:]*::[0-9A-Fa-f:]*(%[A-Za-z0-9._-]+)?(#[0-9]+)?/[address redacted]/g' \
        -e '/^;;/ s/([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(%[A-Za-z0-9._-]+)?(#[0-9]+)?/[address redacted]/g' \
    | redact_internal_names
}

# Install-log lines reach these artifacts only when they match the DNS error pattern,
# and every address literal such a line carries is a resolver or transport endpoint of
# the client that failed: Go reports them as "lookup <name> on <address>:53: ..." and,
# when it keeps the underlying network error, also as "read udp <local>-><remote>: ...".
# None of them belongs to the cluster under test, so all of them are redacted, with or
# without a port and including the zone identifier of a scoped IPv6 address, while the
# names, timestamps and error text that make the line useful are kept.
redact_log_addresses() {
    sed -E \
        -e 's/\[?([0-9]{1,3}\.){3}[0-9]{1,3}\]?(:[0-9]+)?/[address redacted]/g' \
        -e 's/\[[0-9A-Fa-f]*(:[0-9A-Fa-f]*)+(%[A-Za-z0-9._-]+)?\](:[0-9]+)?/[address redacted]/g' \
    | redact_internal_names
}

# Derive the API hostname from an already-fetched cluster description. No API calls.
derive_api_host() {
    local cluster_json="${1:-}"
    local api_url name base_domain

    [[ -n "${cluster_json}" && -f "${cluster_json}" ]] || return 0

    api_url=$(jq -r '.api.url // empty' "${cluster_json}" 2>/dev/null || true)
    if [[ -n "${api_url}" ]]; then
        echo "${api_url}" | sed -e 's|https\?://||' -e 's|:[0-9]*$||'
        return 0
    fi

    name=$(jq -r '.name // empty' "${cluster_json}" 2>/dev/null || true)
    base_domain=$(jq -r '.dns.base_domain // empty' "${cluster_json}" 2>/dev/null || true)
    if [[ -n "${name}" && -n "${base_domain}" ]]; then
        echo "api.${name}.${base_domain}"
    fi
    return 0
}

# Emit a DNS lookup plus the labels needed to read it correctly: who ran it, from where
# and when. Without those labels a successful lookup here is easily misread as evidence
# about the client that originally failed to resolve the name.
print_dns_probe_context() {
    local probe_host="${1:-}"

    echo "Probe origin: the ci-operator step pod running this step on the CI build farm."
    echo "Probe time:   $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
    cat <<'EOF'
Probe resolver: whatever /etc/resolv.conf gives this pod, normally the DNS service of
  the CI build-farm cluster. It is not the resolver used by the ROSA management cluster or by
  the hosted control plane that logged the lookup failure, and seeing the same resolver
  service IP in two clusters does not make it the same resolver.
How to read the result: it describes resolution as seen from this CI pod at the probe
  time printed above. It is not evidence of what the original client resolved, and it
  does not establish when any record was created, changed or propagated.
EOF
    # Only whether this pod has a resolver configuration, never its contents: the
    # nameserver addresses and search domains in /etc/resolv.conf describe the CI build
    # farm, not the cluster under test, and these artifacts are public.
    if [[ -r /etc/resolv.conf ]]; then
        echo "Probe resolver configuration: present (details intentionally not published)."
    else
        echo "Probe resolver configuration: unavailable in this pod."
    fi
    echo ""
    if [[ -n "${probe_host}" ]]; then
        echo "--- dig ${probe_host} (from this CI pod, via this pod's own resolver) ---"
        timeout 10 dig +time=2 +tries=1 "${probe_host}" 2>&1 | redact_resolver_addresses || true
    else
        echo "--- dig skipped: API hostname could not be derived ---"
    fi
    return 0
}

# Preserve the install-log context of a newly observed DNS error while the step is still
# waiting, so a later re-fetch of the install log does not erase the chronology.
capture_dns_observation() {
    local fetch_output="${1:-}"
    local cluster_state="${2:-unknown}"
    local health_check="${3:-0}"
    local dns_lines new_dns_lines observed_at observation_file probe_host
    local observation_index observation_written="yes"
    local capped_dns_lines saved_dns_lines observation_text

    [[ -n "${fetch_output}" ]] || return 0
    [[ -n "${ARTIFACT_DIR:-}" && -d "${ARTIFACT_DIR}" ]] || return 0

    dns_lines=$(grep -E "${DNS_ERROR_PATTERN}" <<< "${fetch_output}" || true)
    [[ -n "${dns_lines}" ]] || return 0
    dns_errors_observed="yes"

    if [[ -z "${dns_errors_seen_file}" ]]; then
        dns_errors_seen_file=$(mktemp) || return 0
    fi
    if [[ -s "${dns_errors_seen_file}" ]]; then
        new_dns_lines=$(grep -Fxv -f "${dns_errors_seen_file}" <<< "${dns_lines}" || true)
    else
        new_dns_lines="${dns_lines}"
    fi
    [[ -n "${new_dns_lines}" ]] || return 0

    observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [[ -n "${dns_first_observed_at}" ]] || dns_first_observed_at="${observed_at}"
    # Past the cap nothing more is written, so nothing more is recorded as seen either:
    # the de-duplication state stops growing with the install log.
    if (( dns_observation_count >= DNS_MAX_OBSERVATIONS )); then
        if [[ "${dns_limit_logged}" != "yes" ]]; then
            dns_limit_logged="yes"
            log "New DNS-related errors observed in install-log output; keeping the first ${DNS_MAX_OBSERVATIONS} observations only."
        fi
        return 0
    fi

    observation_index=$(( dns_observation_count + 1 ))
    observation_file=$(printf '%s/dns-observation-%02d.txt' "${ARTIFACT_DIR}" "${observation_index}")
    probe_host=$(derive_api_host "${cluster_info_json:-}")

    # The byte cap is applied only after the filters have run. Truncating first
    # could cut an address in two and leave a fragment the filters no longer
    # recognise; the line cap already bounds how much text they see.
    capped_dns_lines=$(printf '%s\n' "${new_dns_lines}" | head -n "${DNS_MAX_ERROR_LINES}" \
        | mask_sensitive_output | redact_log_addresses | head -c "${DNS_MAX_ERROR_BYTES}" || true)
    # How many of those lines this snapshot keeps whole. Both caps can leave a line
    # out, and the byte cap can end inside one, so only the complete lines counted
    # here may be recorded as seen below. The filters substitute inside a line and
    # never add or drop one, so the count applies to the source lines as well.
    # Counted from the capped stream rather than from the variable above, which no
    # longer shows whether its last line was terminated.
    saved_dns_lines=$(printf '%s\n' "${new_dns_lines}" | head -n "${DNS_MAX_ERROR_LINES}" \
        | mask_sensitive_output | redact_log_addresses | head -c "${DNS_MAX_ERROR_BYTES}" \
        | tr -cd '\n' | wc -c || true)
    [[ "${saved_dns_lines}" =~ ^[0-9]+$ ]] || saved_dns_lines=0

    # Build the snapshot in memory, then write it with a single command. The exit
    # status of a redirected group command is the status of its last command only,
    # so a write that failed earlier in such a group would go unnoticed; here one
    # command writes the whole snapshot and its status covers all of it.
    observation_text=$(
    {
        echo "=== ROSA install-log DNS error observation ${observation_index} ==="
        echo "Observed at: ${observed_at} (UTC, clock of this CI step pod)"
        echo "Observed by: rosa-cluster-wait-ready-cluster, install-log health check after ${health_check} polls with an unchanged cluster state"
        echo "Cluster:     the one this step run is waiting for; no identifier is published here"
        echo "OCM cluster state at observation: ${cluster_state}"
        echo ""
        echo "Written while the step was still waiting for the cluster, before any fail-fast"
        echo "path re-fetches the install log. The timestamps inside install-log lines are the"
        echo "times recorded by whatever logged those events; the times above only say when"
        echo "this step read them. The captured text is the DNS-matching output of"
        echo "'rosa logs install' (stdout and stderr, so it can also contain this step's own"
        echo "retry messages), with the AWS account IDs known to this step masked and the"
        echo "resolver addresses redacted. No other part of the install log is copied here:"
        echo "when the step gives up it publishes the log it then holds as .install.log."
        echo ""
        echo "=== DNS-related lines not seen in earlier observations (at most ${DNS_MAX_ERROR_LINES} lines, ${DNS_MAX_ERROR_BYTES} bytes) ==="
        printf '%s\n' "${capped_dns_lines}"
        echo ""
        echo "=== DNS probe taken at this observation ==="
        print_dns_probe_context "${probe_host}"
        echo ""
        echo "=== End DNS error observation ${observation_index} ==="
    } 2>&1
    ) || observation_written="no"

    if [[ "${observation_written}" == "yes" ]]; then
        printf '%s\n' "${observation_text}" > "${observation_file}" 2>/dev/null \
            || observation_written="no"
    fi

    # A write that stopped part way through (a full filesystem, for instance) leaves a
    # non-empty file, so the status of the write decides, not the size of the file.
    if [[ "${observation_written}" == "yes" && -f "${observation_file}" && -s "${observation_file}" ]]; then
        dns_observation_count=${observation_index}
        # Only now are these lines recorded as seen, and only the ones this snapshot
        # kept whole, so a line either cap left out or cut short can still be saved
        # by a later poll. A write that failed records nothing, so a later poll can
        # retry the snapshot.
        printf '%s\n' "${new_dns_lines}" | head -n "${saved_dns_lines}" \
            >> "${dns_errors_seen_file}"
        log "DNS-related error observed in install-log output; snapshot saved to ${observation_file}"
    else
        rm -f "${observation_file}" 2>/dev/null || true
        log "DNS-related error observed in install-log output, but the snapshot could not be written."
    fi
    return 0
}

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ ! -z "$REGION" ]]; then
  CLOUD_PROVIDER_REGION="${REGION}"
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Get shared_vpc mask
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  if [[ ! -e "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
    echo "Error: Shared VPC is enabled, but not find .awscred_shared_account, exit now"
    exit 1
  fi
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

  SHARED_VPC_AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text | awk '{print $1}')
  SHARED_VPC_AWS_ACCOUNT_ID_MASK=$(echo "${SHARED_VPC_AWS_ACCOUNT_ID:0:4}***")

  # reset
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
fi

function post_shared_vpc_auto(){
  local -r cluster_info_json=$1; shift
  echo "Shared-VPC: Auto mode is enabled, adding ingress operator arn to shrared-role's trust policy"
  status_description=$(cat $cluster_info_json | jq -r '.status.description')
  match=$(echo ${status_description} | grep -E "^Failed to verify ingress operator for shared VPC:.*OCM is not authorized to perform: sts:AssumeRole on resource:.*" || true)
  echo "Shared-VPC: cluster status: ${status_description}" \
    | sed "s/${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID_MASK}/g" | sed "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g"

  if [[ ${match} != "" ]]; then
    echo "Shared-VPC: Status match, waiting for 2 mins to make sure operator role is ready."
    sleep 120

    account_intaller_role_arn=$(cat "${cluster_info_json}" | jq -r '.aws.sts.role_arn')
    ingress_operator_arn=$(cat "${cluster_info_json}" | jq -r '.aws.sts.operator_iam_roles[] | select(.namespace=="openshift-ingress-operator") .role_arn')
    shared_role_name=$(cat "${cluster_info_json}" | jq -r '.aws.private_hosted_zone_role_arn' | cut -d '/' -f 2)
    echo "Shared-VPC: ingress: ${ingress_operator_arn}, shared_role: ${shared_role_name}, installer: ${account_intaller_role_arn}" \
      | sed "s/${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID_MASK}/g" \
      | sed "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g"

    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
    trust_policy=$(mktemp)
    cat > ${trust_policy} <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "AWS": [
                "${account_intaller_role_arn}",
                "${ingress_operator_arn}"
              ]
          },
          "Action": "sts:AssumeRole",
          "Condition": {}
      }
  ]
}
EOF
    aws iam update-assume-role-policy --role-name ${shared_role_name} --policy-document file://${trust_policy}
    echo "Shared-VPC: Applied new policy."

    echo "Shared-VPC: waiting for 2 mins to make sure the cluster status is up to date."
    sleep 120

    # reset
    export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  else
    echo "Shared-VPC: Status not match, continuing"
  fi
}

# Wait for cluster to be ready
log "Waiting for cluster ready..."
FAILED_INSTALL="no"
cluster_info_json=$(mktemp)
start_time=$(date +"%s")
dyn_start_time=${start_time}
CLUSTER_PREVIOUS_STATE="claim"
record_cluster "timers" "status" "claim"
loop_count=0
install_complete_seen_at=0
while true; do
  retry_cmd 3 10 rosa describe cluster -c "${CLUSTER_ID}" -o json > "${cluster_info_json}"
  CLUSTER_STATE=$(cat ${cluster_info_json} | jq -r '.state')
  log "Cluster state: ${CLUSTER_STATE}"
  current_time=$(date +"%s")
  if [[ "${CLUSTER_STATE}" != "installing" ]]; then
    install_complete_seen_at=0
  fi
  if [[ "${CLUSTER_STATE}" == "error" ]] || (( "${current_time}" - "${start_time}" >= "${CLUSTER_TIMEOUT}" )); then
    record_cluster "timers" "status" "${CLUSTER_STATE}"
    FAILED_INSTALL="yes"
    break
  fi
  if [[ "${CLUSTER_STATE}" != "${CLUSTER_PREVIOUS_STATE}" ]] ; then
    record_cluster "timers" "status" "${CLUSTER_STATE}"
    record_cluster "timers.install" "${CLUSTER_PREVIOUS_STATE}" $(( "${current_time}" - "${dyn_start_time}" ))
    dyn_start_time=${current_time}
    CLUSTER_PREVIOUS_STATE=${CLUSTER_STATE}
    if [[ "${CLUSTER_STATE}" == "ready" ]]; then
      break
    fi
  else
      # Stall detection: fail early if state is stuck for too long
      stall_elapsed=$(( current_time - dyn_start_time ))
      if (( stall_elapsed >= STALL_TIMEOUT )) && [[ "${CLUSTER_STATE}" == "installing" || "${CLUSTER_STATE}" == "pending" ]]; then
        if [[ "${CLUSTER_STATE}" == "installing" ]] && (( install_complete_seen_at > 0 )); then
          log "Cluster has exceeded the general stall timeout, but installer completion was detected; applying the OCM reconciliation timeout."
        else
          log "ERROR: Cluster state '${CLUSTER_STATE}' has not changed for $(( stall_elapsed / 60 )) minutes (stall timeout: $(( STALL_TIMEOUT / 60 )) minutes)"
          log "Cluster appears to be stalled. Failing early."
          record_cluster "timers" "status" "${CLUSTER_STATE}"
          FAILED_INSTALL="yes"
          break
        fi
      fi

      # Install log health check: every 5 iterations, check for fatal errors
      loop_count=$((loop_count + 1))
      if (( loop_count % 5 == 0 )); then
        log "Checking install logs for fatal errors..."
        install_log_output=$(retry_cmd 3 10 timeout 60 rosa logs install -c "${CLUSTER_ID}" 2>&1 || true)
        # Keep the DNS chronology before the fail-fast path below re-fetches the install
        # log. Bounded and best effort: it adds at most one timeout-bounded DNS probe to
        # this poll, and it does not change the step's exit status or failure criteria.
        capture_dns_observation "${install_log_output}" "${CLUSTER_STATE}" "${loop_count}" || true
        fatal_pattern=$(echo "${install_log_output}" | grep -E "ProvisionFailed|failed to create|InvalidSubnet|LimitExceeded|QuotaExceeded|InsufficientFreeAddresses|UnauthorizedAccess" || true)
        # Filter known transient errors. The KMS provider x509 error (OCPBUGS-49661) is caused by
        # the admin-kubeconfig CA not trusting the Let's Encrypt CA on ROSA HCP API servers. CAPI
        # also reports the guest cluster as unreachable while its API server is still bootstrapping.
        if [[ -n "${fatal_pattern}" ]]; then
          fatal_pattern=$(echo "${fatal_pattern}" | grep -v -E 'kms-provider.*x509|x509.*kms-provider|failed to create cluster accessor.*cluster is not reachable' || true)
        fi
        if [[ -n "${fatal_pattern}" ]]; then
          log "ERROR: Fatal error detected in install logs:"
          log "${fatal_pattern}"
          log "Failing early due to unrecoverable error."
          record_cluster "timers" "status" "${CLUSTER_STATE}"
          FAILED_INSTALL="yes"
          break
        fi

        # Provisioner launch detection: for Classic clusters, check if Hive ever started
        if [[ "${HOSTED_CP}" != "true" ]] && [[ "${CLUSTER_STATE}" == "installing" ]]; then
          infra_id_check=$(jq -r '.infra_id' "${cluster_info_json}")
          installing_elapsed=$(( current_time - dyn_start_time ))

          if [[ "${infra_id_check}" == "null" ]] && (( installing_elapsed >= PROVISIONER_LAUNCH_TIMEOUT )); then
            install_log_check=$(retry_cmd 3 10 timeout 60 rosa logs install -c "${CLUSTER_ID}" 2>&1 || true)
            if echo "${install_log_check}" | grep -q "waiting for installation to begin"; then
              log "FATAL: Hive provisioner never launched."
              log "  infra_id is null after $(( installing_elapsed / 60 )) minutes in 'installing' state."
              log "  Install logs still show: 'waiting for installation to begin'"
              log "  This indicates the OCM-to-Hive handoff failed."
              record_cluster "timers" "status" "provisioner_stall"
              FAILED_INSTALL="yes"
              break
            fi
          fi

          # Installer completion can precede the OCM state transition by a short period.
          # Measure reconciliation independently from provisioner launch and install duration.
          if [[ "${infra_id_check}" != "null" ]] && echo "${install_log_output}" | grep -Eiq 'install complete!|install completed successfully'; then
            reconciliation_now=$(date +"%s")
            if (( install_complete_seen_at == 0 )); then
              install_complete_seen_at=${reconciliation_now}
              log "Installer completed while OCM state is still 'installing'; starting the reconciliation timeout."
            fi

            reconciliation_elapsed=$(( reconciliation_now - install_complete_seen_at ))
            if (( reconciliation_elapsed >= OCM_RECONCILIATION_TIMEOUT )); then
              log "FATAL: OCM state reconciliation failure detected."
              log "  infra_id is set (provisioner launched) but cluster is still in 'installing' state"
              log "  $(( reconciliation_elapsed / 60 )) minutes after install logs showed completion."
              log "  This indicates OCM failed to reconcile the cluster state from 'installing' to 'ready'."
              record_cluster "timers" "status" "ocm_state_stall"
              FAILED_INSTALL="yes"
              break
            fi

            log "Waiting for OCM state reconciliation ($(( reconciliation_elapsed / 60 ))/$(( OCM_RECONCILIATION_TIMEOUT / 60 )) minutes)."
          fi
        fi
      fi

      if [[ ${CLUSTER_STATE} == "installing" ]]; then
      	sleep 60
      else
        sleep 1
      fi
  fi
  if [[ "${CLUSTER_STATE}" == "waiting" ]] && [[ "${ENABLE_SHARED_VPC}" == "yes" ]] && [[ "${BYO_OIDC}" == "false" ]]; then
    # Adding ingress role to trust policy
    post_shared_vpc_auto ${cluster_info_json}
  fi
done
[[ -z "${dns_errors_seen_file}" ]] || rm -f "${dns_errors_seen_file}"
cat $cluster_config_file | jq -r '.timers'

if [[ "$FAILED_INSTALL" == "yes" ]]; then
  # Save full cluster description for diagnostics
  rosa describe cluster -c "${CLUSTER_ID}" -o json > "${ARTIFACT_DIR}/cluster-description.json" || true
  # Log the cluster status description
  status_desc=$(jq -r '.status.description // "N/A"' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || echo "N/A")
  log "Cluster status description: ${status_desc}"
  # Save install logs
  timeout 60 rosa logs install -c ${CLUSTER_ID} > "${ARTIFACT_DIR}/.install.log" || true
  # Save Hive ClusterDeployment and AWS AccountClaim status for Classic clusters.
  if [[ "${HOSTED_CP}" != "true" ]]; then
    log "Saving Classic cluster resources..."
    capture_classic_resources || true
  fi
  # Save machinepool/NodePool status for HCP clusters.
  if [[ "${HOSTED_CP}" == "true" ]]; then
    log "Saving HCP machinepool status..."
    rosa list machinepools -c "${CLUSTER_ID}" -o json > "${ARTIFACT_DIR}/machinepools.json" 2> "${ARTIFACT_DIR}/machinepools.json.stderr" || true
    rosa describe machinepool -c "${CLUSTER_ID}" --machinepool workers -o json > "${ARTIFACT_DIR}/machinepool-workers-describe.json" 2> "${ARTIFACT_DIR}/machinepool-workers-describe.json.stderr" || true
  fi
  # DNS diagnostics: when the failure involves DNS resolution errors ("no such host" or
  # "dial tcp: lookup"), capture Route 53 record state and resolver output as artifacts.
  # This helps triage DNS propagation / hosted-zone issues without needing to reproduce.
  dns_pattern_found="no"
  if [[ -f "${ARTIFACT_DIR}/.install.log" ]] && grep -qE "${DNS_ERROR_PATTERN}" "${ARTIFACT_DIR}/.install.log" 2>/dev/null; then
    dns_pattern_found="yes"
  elif echo "${status_desc}" | grep -qE "${DNS_ERROR_PATTERN}" 2>/dev/null; then
    dns_pattern_found="yes"
  elif [[ "${dns_errors_observed}" == "yes" ]]; then
    # The error was seen earlier in the wait loop but is no longer in the final log.
    dns_pattern_found="yes"
  fi
  if [[ "${dns_pattern_found}" == "yes" ]]; then
    log "DNS-related error detected, capturing DNS diagnostics..."
    {
      echo "=== DNS Diagnostics ==="
      echo "Captured at: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC, after the step declared the install failed)"
      echo "Captured by: rosa-cluster-wait-ready-cluster, running in a ci-operator step pod"
      echo "Cluster ID: ${CLUSTER_ID}"
      echo "This file is published as a public CI artifact: resolver addresses and internal"
      echo "infrastructure names are redacted, and no resolver configuration is copied here."
      echo ""
      if [[ "${dns_errors_observed}" == "yes" ]]; then
        echo "Earlier DNS errors were seen in install-log output while the step was still waiting."
        echo "The first was read by this step at ${dns_first_observed_at} (UTC). ${dns_observation_count} bounded snapshot(s)"
        echo "were saved alongside this file as dns-observation-NN.txt; at most ${DNS_MAX_OBSERVATIONS} are kept, so a"
        echo "later observation may have been dropped."
      else
        echo "The wait loop's periodic install-log health checks recorded no DNS error. They run"
        echo "only every few polls and only while the cluster state is unchanged, so this is not"
        echo "evidence that no earlier DNS error occurred."
      fi
      echo ""

      # Extract API URL and cluster DNS zone from the saved cluster description
      api_url=$(jq -r '.api.url // empty' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || true)
      cluster_name=$(jq -r '.name // empty' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || true)
      base_domain=$(jq -r '.dns.base_domain // empty' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || true)

      cluster_zone=""
      if [[ -n "${cluster_name}" && -n "${base_domain}" ]]; then
        cluster_zone="${cluster_name}.${base_domain}"
        echo "Cluster DNS zone: ${cluster_zone}"
      fi

      api_host=""
      if [[ -n "${api_url}" ]]; then
        api_host=$(echo "${api_url}" | sed -e 's|https\?://||' -e 's|:[0-9]*$||')
        echo "API URL: ${api_url}"
        echo "API hostname: ${api_host}"
      elif [[ -n "${cluster_zone}" ]]; then
        api_host="api.${cluster_zone}"
        echo "API URL not available; derived API hostname: ${api_host}"
      else
        echo "API URL and cluster DNS zone not available; skipping DNS probes"
      fi
      echo ""

      # Resolve the API hostname from this CI pod. The probe is labelled with its origin
      # and time because it only describes resolution as seen from CI once the step had
      # already failed; it is not the view of the client that logged the lookup error.
      if [[ -n "${api_host}" ]]; then
        echo "=== DNS probe from this CI step pod ==="
        print_dns_probe_context "${api_host}" || true
        echo ""

        # Look up authoritative nameservers for the cluster zone and query them directly
        ns_zone="${cluster_zone:-$(echo "${api_host}" | cut -d. -f2-)}"
        echo "=== Authoritative NS lookup for ${ns_zone} (queried from this CI pod) ==="
        timeout 10 dig +time=2 +tries=1 NS "${ns_zone}" +short 2>&1 | redact_resolver_addresses || true
        echo ""
        # Keep only an answer: when dig cannot reach a resolver it prints a diagnostic
        # line naming that resolver, and this value is echoed into the public artifact.
        # An NS answer is always a host name ending in a dot, so nothing else is taken.
        auth_ns=$(timeout 10 dig +time=2 +tries=1 NS "${ns_zone}" +short 2>/dev/null \
          | grep -E '^[A-Za-z0-9_.-]+\.$' | head -1 || true)
        if [[ -n "${auth_ns}" ]]; then
          # The query uses the answer as it came; the published header does not, in
          # case the zone is served by an internally named nameserver.
          echo "=== dig @$(printf '%s' "${auth_ns}" | redact_internal_names) ${api_host} (authoritative) ==="
          timeout 10 dig +time=2 +tries=1 "@${auth_ns}" "${api_host}" 2>&1 | redact_resolver_addresses || true
          echo ""
        else
          echo "No authoritative nameservers found for ${ns_zone}"
          echo ""
        fi
      fi

      # Route 53: dump the hosted-zone record sets for the cluster's DNS name
      if aws sts get-caller-identity &>/dev/null; then
        echo "=== Route 53 hosted zone records ==="
        echo "Record state as read at $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC). The API returns no"
        echo "history, so this says nothing about when a record was created or changed."
        if [[ -n "${cluster_zone}" ]]; then
          hz_json=$(aws route53 list-hosted-zones-by-name \
            --dns-name "${cluster_zone}" \
            --max-items 1 \
            --output json 2>/dev/null || true)
          hz_name=$(echo "${hz_json}" | jq -r '.HostedZones[0].Name // empty' 2>/dev/null || true)
          hz_id=$(echo "${hz_json}" | jq -r '.HostedZones[0].Id // empty' 2>/dev/null | sed 's|/hostedzone/||' || true)
          if [[ "${hz_name}" == "${cluster_zone}." ]]; then
            echo "Hosted zone: ${hz_name} (ID: ${hz_id})"
            aws route53 list-resource-record-sets \
              --hosted-zone-id "${hz_id}" \
              --output json 2>&1 || true
          else
            echo "No exact Route 53 hosted zone match for: ${cluster_zone} (closest: ${hz_name:-none})"
          fi
        else
          echo "Cluster DNS zone not available, skipping Route 53 lookup"
        fi
        echo ""
      else
        echo "=== Route 53 ==="
        echo "AWS credentials not available for Route 53 lookup"
        echo ""
      fi

      echo "=== End DNS Diagnostics ==="
      echo "Completed at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${ARTIFACT_DIR}/dns-diagnostics.txt" 2>&1
    log "DNS diagnostics saved to ${ARTIFACT_DIR}/dns-diagnostics.txt"
  fi
  exit 1
fi

# Verify the subnets of the cluster to remove the 'Inflight Checks' warning
if [[ "$ENABLE_BYOVPC" == "true" ]]; then
  verify_cmd=$(rosa verify network -c ${CLUSTER_ID} | grep 'rosa verify network' || true)
  if [[ ! -z "$verify_cmd" ]]; then
    echo -e "Force verifying the network of the cluster to remove the 'Inflight Checks' warning\n$verify_cmd"
    eval $verify_cmd
  fi
fi

# Output
cluster_info_json=$(mktemp)
rosa describe cluster -c "${CLUSTER_ID}" -o json > ${cluster_info_json}
API_URL=$(cat $cluster_info_json | jq -r '.api.url')
CONSOLE_URL=$(cat $cluster_info_json | jq -r '.console.url')
if [[ "${API_URL}" == "null" ]]; then
  port="6443"
  if [[ "$HOSTED_CP" == "true" ]]; then
    port="443"
  fi
  log "warning: API URL was null, attempting to build API URL"
  base_domain=$(cat $cluster_info_json | jq -r '.dns.base_domain')
  CLUSTER_NAME=$(cat $cluster_info_json | jq -r '.name')
  echo "info: Using baseDomain : ${base_domain} and clusterName : ${CLUSTER_NAME}"
  API_URL="https://api.${CLUSTER_NAME}.${base_domain}:${port}"
  CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_NAME}.${base_domain}"
fi
echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
echo "${API_URL}" > "${SHARED_DIR}/api.url"

PRODUCT_ID=$(cat $cluster_info_json | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(cat $cluster_info_json | jq -r '.infra_id')
if [[ "$HOSTED_CP" == "true" ]] && [[ "${INFRA_ID}" == "null" ]]; then
  # Currently, there is no infra_id for rosa hypershift cluster, use a fake one instead of null
  INFRA_ID=$(cat $cluster_info_json | jq -r '.name')
fi
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
