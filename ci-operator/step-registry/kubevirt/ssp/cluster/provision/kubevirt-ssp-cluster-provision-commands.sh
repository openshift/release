#!/bin/bash
# WIP: This is a real HTTP client for a PROPOSED API, not a confirmed integration.
# TODO(API handoff): Agree routes, authentication, request/response fields and
# server-side exclusion/recovery with infrastructure; adapt this script and its
# fixture tests to the delivered contract before enabling rebuilds.
# shellcheck disable=SC2016 # Dollar expressions passed to valid_json belong to jq.
# Do not trace credentials, private endpoints or raw API responses.
set +x
set -euo pipefail
umask 077

# 1. Refuse to contact the API unless rebuilding is enabled and the lease,
# requested version and time limits are valid. Boskos supplies LEASED_RESOURCE.
fail() { echo "$1" >&2; exit 1; }
[[ ${CLUSTER_API_REBUILD_ENABLED:-false} == true ]] || fail "API provisioning is disabled; confirm the contract and dedicated targets before enabling it"
[[ ${CLUSTER_TYPE:-} == libvirt-s390x-vpn-virt ]] || fail "Unexpected cluster profile"
[[ ${LEASED_RESOURCE:-} =~ ^libvirt-s390x-virt-[01]-0$ ]] || fail "A dedicated HA lease is required"
[[ ${PROW_JOB_ID:-} =~ ^[a-zA-Z0-9-]+$ ]] || fail "A Prow job identity is required"
[[ ${CLUSTER_API_OPENSHIFT_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "An approved exact OpenShift version is required"
for value in "${CLUSTER_API_TIMEOUT_SECONDS:-9000}" "${CLUSTER_API_POLL_SECONDS:-30}"; do
  [[ $value =~ ^[1-9][0-9]*$ ]] || fail "API timeouts must be positive integers"
done
budget=${CLUSTER_API_TIMEOUT_SECONDS:-9000}
poll=${CLUSTER_API_POLL_SECONDS:-30}
(( budget <= 9000 && poll <= 60 )) || fail "API timing exceeds the step budget"
: "${SHARED_DIR:?}" "${ARTIFACT_DIR:?}"
[[ ! -e ${SHARED_DIR}/kubeconfig && ! -e ${SHARED_DIR}/cluster-api-operation.json ]] || fail "Refusing to overwrite an earlier provisioning handoff"

# 2. Read the API connection details from the mounted CI secret. The slots file
# limits which reserved clusters this job is allowed to replace.
# TODO(API handoff): Confirm secret group/field names and bearer authentication.
# Only these files are configurable in local fixture tests; CI uses the fixed mount.
credentials=${CLUSTER_API_CREDENTIALS_DIR:-/var/run/cluster-api}
[[ -s $credentials/url && -s $credentials/token && -s $credentials/slots ]] || fail "API url, token and confirmed slot allowlist are required"
url=$(cat "$credentials/url")
token=$(cat "$credentials/token")
[[ $url =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]] || fail "API URL must be an HTTP(S) origin without credentials or query parameters"
[[ $token =~ ^[a-zA-Z0-9._~+/-]+=*$ ]] || fail "Invalid API token format"
grep -Fxq "$LEASED_RESOURCE" "$credentials/slots" || fail "The leased slot is not enabled for API rebuilds"
url=${url%/}
tmp=$(mktemp -d)
started=$SECONDS
accepted=0
outcome=failed
# On every exit, remove temporary credentials and write only a small public
# result. SHARED_DIR is the private handoff between steps; ARTIFACT_DIR is public.
cleanup() {
  local result=$?
  trap - EXIT
  rm -rf "$tmp"
  # No raw responses, credentials, endpoint, slot or node names in public artifacts.
  jq -n --arg outcome "$outcome" --argjson accepted "$accepted" \
    --argjson seconds "$((SECONDS - started))" \
    '{outcome:$outcome,request_attempted:($accepted == 1),elapsed_seconds:$seconds}' \
    > "${ARTIFACT_DIR}/provisioning-summary.json" || true
  if (( result != 0 && accepted == 1 )); then
    echo "Provisioning did not complete; infrastructure must reconcile the operation before another rebuild" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$tmp/curl.conf"
unset token

# Shared HTTP helper: send an authenticated request, save its body privately
# in $tmp/response, and require the expected HTTP status. It never prints the body.
request() {
  local method=$1 path=$2 expected=$3 code remaining attempt transport
  local args=(--request "$method")
  if [[ $method == POST ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "@$tmp/request.json")
  fi
  # Never follow redirects or retry a destructive request. Read-only transient
  # failures get at most three attempts, all within the same overall deadline.
  for attempt in 1 2 3; do
    remaining=$((budget - (SECONDS - started)))
    (( remaining > 0 )) || fail "Provisioning deadline exceeded"
    (( remaining <= 60 )) || remaining=60
    transport=0
    code=$(curl -q --silent --config "$tmp/curl.conf" --proto '=http,https' \
      --connect-timeout 15 --max-time "$remaining" \
      --output "$tmp/response" --write-out '%{http_code}' "${args[@]}" "$url$path" 2>/dev/null) || transport=$?
    if (( transport == 0 )) && [[ $code == "$expected" ]]; then
      return
    fi
    if [[ $method != GET || $attempt == 3 ]] || { (( transport == 0 )) && [[ ! $code =~ ^5[0-9][0-9]$ ]]; }; then
      fail "Infrastructure API request failed; inspect server-side operation state"
    fi
    (( SECONDS - started + 2 < budget )) || fail "Provisioning deadline exceeded"
    sleep 2
  done
}

valid_json() { jq -e "$@" "$tmp/response" >/dev/null 2>&1 || fail "Infrastructure API response did not match the expected contract"; }

# 3. Read the slot before rebuilding. Save its old identity so a stale cluster
# cannot be accepted as the result of a new installation.
# TODO(API handoff): Confirm slot naming, state/identity fields, rebuild payload
# and HTTP status codes. The routes and JSON checks below implement our proposal.
request GET "/v1/clusters/$LEASED_RESOURCE" 200
valid_json --arg slot "$LEASED_RESOURCE" '
  .slot == $slot and (.state == "empty" or (.state == "ready" and
    (.generation | type == "string" and length > 0) and
    (.cluster_id | type == "string" and test("^[a-fA-F0-9-]{36}$"))))'
old_cluster=$(jq -r '.cluster_id // ""' "$tmp/response")
old_generation=$(jq -r '.generation // ""' "$tmp/response")
# 4. Request exactly one rebuild. request_id identifies this CI attempt;
# build_id tracks the API operation, and generation identifies the installation.
jq -n --arg id "$PROW_JOB_ID-$LEASED_RESOURCE" --arg version "$CLUSTER_API_OPENSHIFT_VERSION" \
  '{request_id:$id,openshift_version:$version}' > "$tmp/request.json"
# Persist correlation before POST so a lost response can be reconciled by request ID.
cp "$tmp/request.json" "${SHARED_DIR}/cluster-api-operation.json"
accepted=1
# TODO(API handoff): Confirm request_id deduplication and exclusive installation
# survive API restarts and CI cancellation; client fixtures cannot prove this.
request POST "/v1/clusters/$LEASED_RESOURCE/rebuild" 202
valid_json --arg slot "$LEASED_RESOURCE" --arg old "$old_generation" '
  def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
  .slot == $slot and .state == "running" and (.build_id|id) and
  (.generation|id) and .generation != $old'
build=$(jq -r .build_id "$tmp/response")
generation=$(jq -r .generation "$tmp/response")
jq --arg build "$build" --arg generation "$generation" --arg slot "$LEASED_RESOURCE" \
  '. + {build_id:$build,generation:$generation,slot:$slot}' "$tmp/request.json" \
  > "${SHARED_DIR}/cluster-api-operation.json"
echo "Provisioning request accepted; waiting for completion"
# 5. Poll installation status. Only a matching ready operation can continue;
# failed operations, unexpected responses and the deadline stop the job.
while true; do
  request GET "/v1/builds/$build" 200
  valid_json --arg build "$build" --arg generation "$generation" --arg slot "$LEASED_RESOURCE" \
    --arg version "$CLUSTER_API_OPENSHIFT_VERSION" '
    .build_id == $build and .generation == $generation and .slot == $slot and
    .openshift_version == $version and (.state == "running" or .state == "ready" or .state == "failed")'
  state=$(jq -r .state "$tmp/response")
  [[ $state != failed ]] || fail "Infrastructure reported an installation failure"
  if [[ $state == ready ]]; then
    valid_json '.release_image | type == "string" and test("^[^[:space:]]+@sha256:[a-f0-9]{64}$")'
    release=$(jq -r .release_image "$tmp/response")
    break
  fi
  (( SECONDS - started + poll < budget )) || fail "Provisioning deadline exceeded"
  sleep "$poll"
done

# 6. Read the completed slot again and match it to the operation we waited for.
# Save the identity/release that the next step must verify against the live cluster.
request GET "/v1/clusters/$LEASED_RESOURCE" 200
valid_json --arg build "$build" --arg generation "$generation" --arg slot "$LEASED_RESOURCE" \
  --arg version "$CLUSTER_API_OPENSHIFT_VERSION" --arg release "$release" --arg old_cluster "$old_cluster" '
  .state == "ready" and .build_id == $build and .generation == $generation and .slot == $slot and
  .openshift_version == $version and .release_image == $release and
  (.cluster_id | type == "string" and test("^[a-fA-F0-9-]{36}$")) and .cluster_id != $old_cluster'
jq '{cluster_id,openshift_version,release_image}' "$tmp/response" > "$tmp/expected.json"
# 7. Download credentials for this installation. request() writes the HTTP
# response body to $tmp/response; the following checks read that local file.
# TODO(API handoff): Confirm kubeconfig retrieval and stale-generation rejection.
# Preserve the private SHARED_DIR/kubeconfig handoff when adapting the transport.
request GET "/v1/clusters/$LEASED_RESOURCE/kubeconfig?generation=$generation" 200
# Parsing is local. Reject executable credential plugins, external files, proxies
# and disabled TLS before making any request with the returned credentials.
if ! oc config view --kubeconfig="$tmp/response" --raw -o json > "$tmp/config.json" 2>/dev/null; then
  fail "API returned an invalid kubeconfig"
fi
# Keep each rule separate so a failure tells us what needs correcting.
# Only the fixed message is public; jq errors may contain private input data.
check_config() {
  local message=$1 filter=$2
  jq -e "$filter" "$tmp/config.json" >/dev/null 2>&1 || fail "$message"
}

# Structure: one unambiguous context pointing to the supplied cluster and user.
check_config "Kubeconfig must contain exactly one cluster" '.clusters | length == 1'
check_config "Kubeconfig must contain exactly one context" '.contexts | length == 1'
check_config "Kubeconfig must contain exactly one user" '.users | length == 1'
check_config "Kubeconfig current context does not match" '.["current-context"] == .contexts[0].name'
check_config "Kubeconfig context references a different cluster" '.contexts[0].context.cluster == .clusters[0].name'
check_config "Kubeconfig context references a different user" '.contexts[0].context.user == .users[0].name'

# Connection: HTTPS with embedded CA data and no proxy or external CA file.
check_config "Kubeconfig endpoint must use HTTPS" '.clusters[0].cluster.server | startswith("https://")'
check_config "Kubeconfig must embed CA data" '.clusters[0].cluster["certificate-authority-data"] | type == "string" and length > 0'
check_config "Kubeconfig must not disable TLS verification" '.clusters[0].cluster["insecure-skip-tls-verify"] != true'
for field in certificate-authority proxy-url; do
  check_config "Kubeconfig must not use $field" \
    ".clusters[0].cluster | has(\"$field\") | not"
done

# Credentials: never execute a plugin or read a file named by the API response.
for field in exec auth-provider tokenFile client-certificate client-key; do
  check_config "Kubeconfig must not use $field" \
    ".users[0].user | has(\"$field\") | not"
done
# Either an embedded token OR an embedded certificate/key pair is accepted.
if ! jq -e '.users[0].user.token | type == "string" and length > 0' \
  "$tmp/config.json" >/dev/null 2>&1; then
  check_config "Kubeconfig needs a token or embedded client certificate" \
    '.users[0].user["client-certificate-data"] | type == "string" and length > 0'
  check_config "Kubeconfig client certificate needs an embedded key" \
    '.users[0].user["client-key-data"] | type == "string" and length > 0'
fi
# 8. Publish the validated handoff only after all checks pass. Later steps set
# KUBECONFIG to this shared file; credentials never go into public artifacts.
cp "$tmp/expected.json" "${SHARED_DIR}/cluster-api-expected.json"
cp "$tmp/response" "${SHARED_DIR}/kubeconfig"
chmod 600 "${SHARED_DIR}/kubeconfig"
outcome=provisioned
echo "Fresh kubeconfig obtained; cluster verification follows"
