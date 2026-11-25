#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This step handles private-key material and several short-lived credentials.
# Disable inherited xtrace before any of them are read or constructed.
WAS_TRACING=false
[[ $- == *x* ]] && WAS_TRACING=true
set +x

# helper to make things more readable below
b64url() {
  openssl base64 -e \
    | tr '/+' '_-' \
    | tr -d '=' \
    | tr -d '\n'
}

# The registry step timeout is 900 seconds. All network retries share one
# monotonic deadline 840 seconds from startup, leaving 60 seconds for orderly
# failure. Preflight work (token exchange, clone, fetch, and branch discovery)
# is capped at 600 seconds, reserving the final 240 seconds for local merge
# work, push, and final GitHub API operations.
STEP_TIMEOUT_SECONDS=${STEP_TIMEOUT_SECONDS:-900}
WORKFLOW_SHUTDOWN_RESERVE_SECONDS=${WORKFLOW_SHUTDOWN_RESERVE_SECONDS:-60}
WORKFLOW_FINALIZATION_RESERVE_SECONDS=${WORKFLOW_FINALIZATION_RESERVE_SECONDS:-240}
RETRY_MAX_ATTEMPTS=${RETRY_MAX_ATTEMPTS:-3}
RETRY_INITIAL_DELAY_SECONDS=${RETRY_INITIAL_DELAY_SECONDS:-2}
CURL_CONNECT_TIMEOUT_SECONDS=${CURL_CONNECT_TIMEOUT_SECONDS:-10}
CURL_MAX_TIME_SECONDS=${CURL_MAX_TIME_SECONDS:-30}
GIT_COMMAND_TIMEOUT_SECONDS=${GIT_COMMAND_TIMEOUT_SECONDS:-120}
GIT_KILL_AFTER_SECONDS=${GIT_KILL_AFTER_SECONDS:-5}
MAX_RETRY_DELAY_SECONDS=999999999999999999

monotonic_seconds() {
  local uptime
  IFS=' ' read -r uptime _ < /proc/uptime
  printf '%s\n' "${uptime%%.*}"
}

if (( WORKFLOW_SHUTDOWN_RESERVE_SECONDS + WORKFLOW_FINALIZATION_RESERVE_SECONDS >= STEP_TIMEOUT_SECONDS )); then
  echo "Invalid retry budgets: reserves must be smaller than the ${STEP_TIMEOUT_SECONDS}s step timeout" >&2
  exit 2
fi

WORKFLOW_START_SECONDS=$(monotonic_seconds)
WORKFLOW_DEADLINE_SECONDS=$((WORKFLOW_START_SECONDS + STEP_TIMEOUT_SECONDS - WORKFLOW_SHUTDOWN_RESERVE_SECONDS))
PREFLIGHT_DEADLINE_SECONDS=$((WORKFLOW_DEADLINE_SECONDS - WORKFLOW_FINALIZATION_RESERVE_SECONDS))

remaining_seconds() {
  local deadline="$1"
  local now
  now=$(monotonic_seconds)
  if (( now >= deadline )); then
    return 1
  fi
  printf '%s\n' "$((deadline - now))"
}

sleep_before_retry() {
  local operation="$1" delay="$2" deadline="$3"
  local remaining normalized_delay
  if ! normalized_delay=$(normalize_decimal_seconds "${delay}"); then
    echo "${operation} cannot retry: invalid retry delay '${delay}'" >&2
    return 124
  fi
  delay=${normalized_delay}
  if ! remaining=$(remaining_seconds "${deadline}"); then
    echo "${operation} cannot retry: shared workflow retry deadline is exhausted" >&2
    return 124
  fi
  if (( delay >= remaining )); then
    echo "${operation} cannot honor a ${delay}s retry delay with only ${remaining}s left before the shared deadline" >&2
    return 124
  fi
  sleep "${delay}"
}

normalize_decimal_seconds() {
  local value="$1" normalized max_length
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1

  # Strip leading zeroes before arithmetic so values such as 08 are never
  # interpreted as octal. Clamp values that do not fit the supported range.
  normalized=${value#"${value%%[!0]*}"}
  [[ -n "${normalized}" ]] || normalized=0
  max_length=${#MAX_RETRY_DELAY_SECONDS}
  if (( ${#normalized} > max_length )); then
    normalized=${MAX_RETRY_DELAY_SECONDS}
  fi
  printf '%s\n' "$((10#${normalized}))"
}

http_header_value() {
  local header_file="$1" header_name="$2"
  awk -v header_name="${header_name}" '
    BEGIN { IGNORECASE = 1 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (index(tolower(line), tolower(header_name) ":") == 1) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        value = line
      }
    }
    END { if (value != "") print value }
  ' "${header_file}"
}

is_rate_limited_response() {
  local status="$1" header_file="$2"
  local retry_after remaining
  [[ "${status}" == "429" ]] && return 0
  [[ "${status}" == "403" ]] || return 1
  retry_after=$(http_header_value "${header_file}" "Retry-After")
  remaining=$(http_header_value "${header_file}" "X-RateLimit-Remaining")
  [[ -n "${retry_after}" || "${remaining}" == "0" ]]
}

is_transient_http_status() {
  local status="$1" header_file="$2"
  case "${status}" in
    408|500|502|503|504) return 0 ;;
    403|429) is_rate_limited_response "${status}" "${header_file}" ;;
    *) return 1 ;;
  esac
}

is_transient_curl_error() {
  # DNS, connection, timeout, TLS handshake, truncated transfer, and HTTP/2
  # transport errors. Certificate validation and authentication errors are
  # intentionally not retryable.
  case "$1" in
    5|6|7|16|18|28|35|52|55|56|92) return 0 ;;
    *) return 1 ;;
  esac
}

redact_output() {
  local output
  output=$(head -c 2048)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    output=${output//"${GITHUB_TOKEN}"/[REDACTED]}
  fi
  if [[ -n "${GIT_AUTH_HEADER:-}" ]]; then
    output=${output//"${GIT_AUTH_HEADER}"/[REDACTED]}
  fi
  if [[ -n "${JWT:-}" ]]; then
    output=${output//"${JWT}"/[REDACTED]}
  fi
  printf '%s\n' "${output}" | sed -E 's#https://[^/@[:space:]]+(:[^/@[:space:]]+)?@#https://[REDACTED]@#g'
}

print_api_failure_details() {
  local response_file="$1" error_file="$2" suppress_response_body="${3:-false}"
  if [[ -s "${error_file}" ]]; then
    echo "curl diagnostic:" >&2
    redact_output < "${error_file}" >&2
  fi
  if [[ -s "${response_file}" ]]; then
    if [[ "${suppress_response_body}" == "true" ]]; then
      # Token-exchange responses contain a credential on success, including
      # partial success bodies left behind by curl transport failures. Never
      # read one into a shell variable or diagnostic stream: the credential is
      # not yet available to redact when curl fails before assignment.
      echo "GitHub response body suppressed because it may contain credentials" >&2
    else
      echo "GitHub response:" >&2
      redact_output < "${response_file}" >&2
    fi
  fi
}

request_method() {
  local method=GET previous="" argument
  for argument in "$@"; do
    if [[ "${previous}" == "request" ]]; then
      method=${argument^^}
      previous=""
      continue
    fi
    case "${argument}" in
      -X|--request) previous=request ;;
      --request=*) method=${argument#*=}; method=${method^^} ;;
      -d|--data|--data-raw|--data-binary|--data-urlencode)
        [[ "${method}" != "GET" ]] || method=POST
        ;;
    esac
  done
  printf '%s\n' "${method}"
}

retry_delay_from_headers() {
  local header_file="$1" fallback="$2"
  local retry_after reset_at now_epoch parsed
  retry_after=$(http_header_value "${header_file}" "Retry-After")
  if parsed=$(normalize_decimal_seconds "${retry_after}"); then
    printf '%s\n' "${parsed}"
    return
  fi
  if [[ -n "${retry_after}" ]] && parsed=$(date -d "${retry_after}" +%s 2>/dev/null); then
    now_epoch=$(date +%s)
    if [[ "${parsed}" == -* ]]; then
      printf '0\n'
    elif parsed=$(normalize_decimal_seconds "${parsed}"); then
      (( parsed > now_epoch )) && printf '%s\n' "$((parsed - now_epoch))" || printf '0\n'
    else
      printf '%s\n' "${fallback}"
    fi
    return
  fi
  reset_at=$(http_header_value "${header_file}" "X-RateLimit-Reset")
  if reset_at=$(normalize_decimal_seconds "${reset_at}"); then
    now_epoch=$(date +%s)
    (( reset_at > now_epoch )) && printf '%s\n' "$((reset_at - now_epoch))" || printf '0\n'
    return
  fi
  printf '%s\n' "${fallback}"
}

# Make a GitHub API request. Successful response bodies are written to stdout.
# POST is deliberately attempted only once: a transport failure can occur after
# GitHub committed the mutation, and replaying it could create duplicate PRs or
# comments. Safe methods retry only within the shared monotonic deadline. The
# authentication scheme and credential are written to a protected header file
# that curl reads with @file syntax, keeping the Authorization value out of argv.
github_api_request() {
  local operation="$1"
  local deadline="$2"
  local auth_scheme="$3"
  local auth_credential="$4"
  shift 4

  local suppress_response_body=false
  if [[ "${1:-}" == "--sensitive-response" ]]; then
    suppress_response_body=true
    shift
  fi

  local attempt curl_rc http_code http_detail delay method max_attempts remaining max_time connect_timeout
  local response_file error_file header_file auth_header_file
  response_file=$(mktemp)
  error_file=$(mktemp)
  header_file=$(mktemp)
  auth_header_file=$(umask 077; mktemp)
  chmod 600 "${auth_header_file}"
  case "${auth_scheme}" in
    Bearer|token) ;;
    *)
      echo "GitHub API operation '${operation}' has unsupported authentication scheme '${auth_scheme}'" >&2
      rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
      return 2
      ;;
  esac
  if [[ "${auth_credential}" == *$'\n'* || "${auth_credential}" == *$'\r'* ]]; then
    echo "GitHub API operation '${operation}' received an invalid authentication credential" >&2
    rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
    return 2
  fi
  printf 'Authorization: %s %s\n' "${auth_scheme}" "${auth_credential}" > "${auth_header_file}"
  auth_credential=
  delay=${RETRY_INITIAL_DELAY_SECONDS}
  method=$(request_method "$@")
  max_attempts=${RETRY_MAX_ATTEMPTS}
  [[ "${method}" != "POST" ]] || max_attempts=1

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    : > "${response_file}"
    : > "${error_file}"
    : > "${header_file}"
    if ! remaining=$(remaining_seconds "${deadline}"); then
      echo "GitHub API operation '${operation}' cannot start: shared workflow retry deadline is exhausted" >&2
      rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
      return 124
    fi
    max_time=${CURL_MAX_TIME_SECONDS}
    (( max_time <= remaining )) || max_time=${remaining}
    connect_timeout=${CURL_CONNECT_TIMEOUT_SECONDS}
    (( connect_timeout <= max_time )) || connect_timeout=${max_time}
    curl_rc=0
    http_code=$(
      curl --disable --silent --show-error \
        --connect-timeout "${connect_timeout}" \
        --max-time "${max_time}" \
        --dump-header "${header_file}" \
        --output "${response_file}" \
        --write-out '%{http_code}' \
        --header "@${auth_header_file}" \
        "$@" 2>"${error_file}"
    ) || curl_rc=$?
    http_detail=""
    if [[ "${http_code}" =~ ^[0-9][0-9][0-9]$ ]]; then
      http_detail=" (HTTP ${http_code})"
    fi

    if [[ ${curl_rc} -eq 0 && "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
      cat "${response_file}"
      rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
      return 0
    fi

    if [[ "${method}" == "POST" ]]; then
      if [[ ${curl_rc} -eq 0 ]]; then
        echo "GitHub API operation '${operation}' failed with HTTP ${http_code}; POST requests are not retried" >&2
        curl_rc=22
      else
        echo "GitHub API operation '${operation}' failed with curl exit ${curl_rc}${http_detail}; POST requests are not retried because the result may be ambiguous" >&2
      fi
      print_api_failure_details "${response_file}" "${error_file}" "${suppress_response_body}"
      rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
      return "${curl_rc}"
    fi

    if [[ ${curl_rc} -eq 0 ]] && is_transient_http_status "${http_code}" "${header_file}"; then
      if (( attempt == max_attempts )); then
        echo "GitHub API operation '${operation}' failed after ${attempt} attempts (last HTTP ${http_code})" >&2
        print_api_failure_details "${response_file}" "${error_file}" "${suppress_response_body}"
        rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
        return 22
      fi
      if is_rate_limited_response "${http_code}" "${header_file}"; then
        delay=$(retry_delay_from_headers "${header_file}" "${delay}")
      fi
      echo "GitHub API operation '${operation}' returned transient HTTP ${http_code} (attempt ${attempt}/${max_attempts}); retrying in ${delay}s" >&2
    elif [[ ${curl_rc} -ne 0 ]] && is_transient_curl_error "${curl_rc}"; then
      if (( attempt == max_attempts )); then
        echo "GitHub API operation '${operation}' failed after ${attempt} attempts (last curl exit ${curl_rc})" >&2
        print_api_failure_details "${response_file}" "${error_file}" "${suppress_response_body}"
        rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
        return "${curl_rc}"
      fi
      echo "GitHub API operation '${operation}' had a transient transport failure (attempt ${attempt}/${max_attempts}, curl exit ${curl_rc}); retrying in ${delay}s" >&2
    else
      if [[ ${curl_rc} -eq 0 ]]; then
        echo "GitHub API operation '${operation}' failed with HTTP ${http_code}; not retrying" >&2
        curl_rc=22
      else
        echo "GitHub API operation '${operation}' failed with curl exit ${curl_rc}; not retrying" >&2
      fi
      print_api_failure_details "${response_file}" "${error_file}" "${suppress_response_body}"
      rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
      return "${curl_rc}"
    fi

    if ! sleep_before_retry "GitHub API operation '${operation}'" "${delay}" "${deadline}"; then
      print_api_failure_details "${response_file}" "${error_file}" "${suppress_response_body}"
      rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
      return 124
    fi
    delay=$((delay * 2))
  done

  rm -f "${response_file}" "${error_file}" "${header_file}" "${auth_header_file}"
  return 1
}

is_transient_git_error() {
  local output_file="$1"
  grep -Eqi \
    'Could not resolve host|Failed to connect|Connection timed out|Connection reset by peer|TLS connection was non-properly terminated|remote end hung up unexpectedly|early EOF|HTTP[/ ][^ ]* (408|429|500|502|503|504)|requested URL returned error: (408|429|500|502|503|504)|HTTP/2 stream .* was not closed cleanly|remote: (Internal Server Error|Service Unavailable)' \
    "${output_file}"
}

# Retry only known transient git transport failures. The optional cleanup path
# is used by clone so a partial destination never turns a retry into a false
# permanent failure.
retry_git() {
  local operation="$1"
  local cleanup_path="$2"
  local deadline="$3"
  shift 3

  local attempt git_rc delay output_file remaining command_timeout
  output_file=$(mktemp)
  delay=${RETRY_INITIAL_DELAY_SECONDS}

  for ((attempt = 1; attempt <= RETRY_MAX_ATTEMPTS; attempt++)); do
    if [[ -n "${cleanup_path}" ]]; then
      rm -rf -- "${cleanup_path}"
    fi
    : > "${output_file}"
    if ! remaining=$(remaining_seconds "${deadline}"); then
      echo "Git operation '${operation}' cannot start: shared workflow retry deadline is exhausted" >&2
      rm -f "${output_file}"
      return 124
    fi
    if (( remaining <= GIT_KILL_AFTER_SECONDS )); then
      echo "Git operation '${operation}' cannot start with only ${remaining}s left before the shared deadline" >&2
      rm -f "${output_file}"
      return 124
    fi
    command_timeout=${GIT_COMMAND_TIMEOUT_SECONDS}
    (( command_timeout + GIT_KILL_AFTER_SECONDS <= remaining )) || command_timeout=$((remaining - GIT_KILL_AFTER_SECONDS))
    git_rc=0
    timeout --kill-after="${GIT_KILL_AFTER_SECONDS}s" \
      "${command_timeout}s" "$@" >"${output_file}" 2>&1 || git_rc=$?

    if [[ ${git_rc} -eq 0 ]]; then
      redact_output < "${output_file}" >&2
      rm -f "${output_file}"
      return 0
    fi

    if [[ ${git_rc} -eq 124 || ${git_rc} -eq 137 ]] || is_transient_git_error "${output_file}"; then
      if (( attempt == RETRY_MAX_ATTEMPTS )); then
        redact_output < "${output_file}" >&2
        echo "Git operation '${operation}' failed after ${attempt} attempts (last exit ${git_rc})" >&2
        rm -f "${output_file}"
        return "${git_rc}"
      fi
      echo "Git operation '${operation}' had a transient failure (attempt ${attempt}/${RETRY_MAX_ATTEMPTS}); retrying in ${delay}s" >&2
    else
      redact_output < "${output_file}" >&2
      echo "Git operation '${operation}' failed with exit ${git_rc}; not retrying" >&2
      rm -f "${output_file}"
      return "${git_rc}"
    fi

    if ! sleep_before_retry "Git operation '${operation}'" "${delay}" "${deadline}"; then
      redact_output < "${output_file}" >&2
      rm -f "${output_file}"
      return 124
    fi
    delay=$((delay * 2))
  done
}

# Delete all remote branches whose names start with "d/s-merge".
# Any branch names passed as arguments are skipped (e.g. heads of open PRs).
delete_ds_merge_branches() {
  local skip_branches=("$@")
  local refs branch keep skip

  echo "🧹 Cleaning up d/s-merge branches…"
  refs=$(
    github_api_request "list downstream merge branches" "${PREFLIGHT_DEADLINE_SECONDS}" token "${GITHUB_TOKEN}" \
      "https://api.github.com/repos/${DOWNSTREAM_REPO}/git/matching-refs/heads/d/s-merge" |
      jq -r '.[].ref // empty' | sed 's|^refs/heads/||'
  )

  if [[ -z "${refs}" ]]; then
    echo "ℹ️  No d/s-merge branches found."
    return 0
  fi

  while IFS= read -r branch; do
    [[ -z "${branch}" ]] && continue
    skip=false
    for keep in "${skip_branches[@]}"; do
      if [[ "${branch}" == "${keep}" ]]; then
        skip=true
        break
      fi
    done
    if [[ "${skip}" == "true" ]]; then
      echo "⏭️  Skipping branch ${branch} (associated with open PR)"
      continue
    fi
    echo "🗑️  Deleting branch ${branch}…"
    github_api_request "delete downstream merge branch" "${PREFLIGHT_DEADLINE_SECONDS}" token "${GITHUB_TOKEN}" -X DELETE \
      "https://api.github.com/repos/${DOWNSTREAM_REPO}/git/refs/heads/${branch}" || true
  done <<< "${refs}"
}

echo "🔐 Generating JWT…"
# create the JWT needed to get an app install token needed for API requests
# the token is short-lived and will expire after EXP below
NOW=$(date +%s)
EXP=$((NOW + 600))
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$GITHUB_APP_ID" | b64url)
SIG_INPUT="$HEADER.$PAYLOAD"

echo "🖋 Signing JWT…"
SIGNATURE=$(
  printf '%s' "$SIG_INPUT" \
    | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_FILE" \
    | b64url
)
JWT="$HEADER.$PAYLOAD.$SIGNATURE"

echo "🔗 Exchanging JWT for installation token…"
INSTALLATION_ID=$(github_api_request "get app installation" "${PREFLIGHT_DEADLINE_SECONDS}" Bearer "${JWT}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/installation" | jq -r .id)
GITHUB_TOKEN=$(github_api_request "create installation token" "${PREFLIGHT_DEADLINE_SECONDS}" Bearer "${JWT}" --sensitive-response -H "Accept: application/vnd.github+json" -X POST \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" | jq -r .token)
echo "✅ Received install token (ID: ${INSTALLATION_ID})"

# For backward compatibility, use DEFAULT_BRANCH for upstream if UPSTREAM_BRANCH not set
if [[ -z "${UPSTREAM_BRANCH:-}" ]]; then
  UPSTREAM_BRANCH="${DEFAULT_BRANCH}"
  echo "ℹ️  UPSTREAM_BRANCH not set, using DEFAULT_BRANCH (${DEFAULT_BRANCH}) for upstream"
fi

echo "📥 Cloning repo and setting up remotes…"
# get the repo
WORKDIR="$(mktemp -d)"
cd "$WORKDIR"
retry_git "clone downstream repository" repo "${PREFLIGHT_DEADLINE_SECONDS}" git clone --single-branch --branch "${DEFAULT_BRANCH}" "https://github.com/${DOWNSTREAM_REPO}" repo
cd repo
git remote add upstream "https://github.com/${UPSTREAM_REPO}"
retry_git "fetch upstream branch" "" "${PREFLIGHT_DEADLINE_SECONDS}" git fetch upstream "${UPSTREAM_BRANCH}"
retry_git "fetch downstream branch" "" "${PREFLIGHT_DEADLINE_SECONDS}" git fetch origin "${DEFAULT_BRANCH}"

echo "🔍 Checking for open downstream-merge PR…"
# check if a d/s merge PR is already open. This requires the PR titles to have the
# below format. As long as this automation is the one creating the PRs it will stay
# in this format. If something/someone else had created a d/s merge PR without this
# format, then we will still get a new one created with this script. Another person
# or process that uses this format is still ok and this automation will recognize it
# and exit early if there’s already an *open* d/s merge PR
OPEN_PR_INFO=$(
  github_api_request "list open downstream merge pull requests" "${PREFLIGHT_DEADLINE_SECONDS}" token "${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls?state=open&base=${DEFAULT_BRANCH}&per_page=100&sort=created&direction=desc" |
    jq -r '.[] | select(.title|test("DownStream Merge \\[[0-9]{2}-[0-9]{2}-[0-9]{4}\\]")) | "\(.number)\t\(.head.ref)"'
)
OPEN_PR_NUMS=()
OPEN_PR_BRANCHES=()
while IFS=$'\t' read -r pr_num pr_branch; do
  [[ -z "${pr_num}" ]] && continue
  OPEN_PR_NUMS+=("${pr_num}")
  OPEN_PR_BRANCHES+=("${pr_branch}")
done <<< "${OPEN_PR_INFO}"

if [[ ${#OPEN_PR_NUMS[@]} -gt 0 ]]; then
  echo "ℹ️  Found open downstream-merge PR(s): ${OPEN_PR_NUMS[*]} (branches: ${OPEN_PR_BRANCHES[*]})"
  delete_ds_merge_branches "${OPEN_PR_BRANCHES[@]}"
  echo "ℹ️  Exiting without creating a new merge PR."
  exit 0
fi

# no open PRs: remove every leftover d/s-merge branch before creating a new one
delete_ds_merge_branches

echo "📊 Counting new commits upstream…"
# to save on overhead we don't need to open a new d/s merge PR until we have enough commits to bring in
NEW_COMMITS=$(git rev-list origin/"${DEFAULT_BRANCH}"..upstream/"${UPSTREAM_BRANCH}" --count)
echo "Found $NEW_COMMITS new commits upstream."
(( NEW_COMMITS < MIN_COMMITS )) && { echo "⚠️  Not enough commits (min=${MIN_COMMITS}); exiting."; exit 0; }

BRANCH="d/s-merge-$(date +%m-%d-%Y)"

echo "🌿 Creating merge branch ${BRANCH} and merging…"
# if we made it this far, we can create the merge and push the PR
git checkout -b "$BRANCH" origin/"${DEFAULT_BRANCH}"
# if there happens to be a merge conflict we can still push it and create a PR...
if ! git merge "upstream/${UPSTREAM_BRANCH}"; then
  echo "⚠️  Merge conflict detected"

  CONFLICTED_FILES=$(git diff --name-only --diff-filter=U)
  echo "Conflicted files:"
  echo "$CONFLICTED_FILES"

  # Capture conflict snippets before git add stages them away
  CONFLICT_SNIPPETS=""
  while IFS= read -r cfile; do
    snippet=$(grep -A5 -B2 '<<<<<<<\|=======\|>>>>>>>' "$cfile" | head -40)
    CONFLICT_SNIPPETS+=$'\n'"**\`${cfile}\`:**"$'\n'"\`\`\`diff"$'\n'"${snippet}"$'\n'"\`\`\`"$'\n'
  done <<< "$CONFLICTED_FILES"

  # Capture upstream commits that touched the conflicted files
  UPSTREAM_FILE_CONTEXT=""
  while IFS= read -r cfile; do
    file_log=$(git log --oneline origin/"${DEFAULT_BRANCH}"..upstream/"${UPSTREAM_BRANCH}" -- "$cfile")
    if [[ -n "$file_log" ]]; then
      UPSTREAM_FILE_CONTEXT+=$'\n'"**\`${cfile}\`:**"$'\n'"\`\`\`"$'\n'"${file_log}"$'\n'"\`\`\`"$'\n'
    fi
  done <<< "$CONFLICTED_FILES"

  MERGE_BASE=$(git merge-base origin/"${DEFAULT_BRANCH}" upstream/"${UPSTREAM_BRANCH}")
  COMPARE_URL="https://github.com/${UPSTREAM_REPO}/compare/${MERGE_BASE}...${UPSTREAM_BRANCH}"

  git add -A
  CONFLICT_MSG="Merge upstream/${UPSTREAM_BRANCH} into ${DEFAULT_BRANCH} with conflicts ($(date +%m-%d-%Y))

Conflicted files:
$CONFLICTED_FILES"
  git commit -m "$CONFLICT_MSG"
  CONFLICT=true
fi

# Skip go mod tidy and test sync if there are conflicts - they should be run after manual resolution
if [[ "${CONFLICT:-false}" == "true" ]]; then
  echo "⚠️  Skipping go mod tidy and test sync due to merge conflicts"
  echo "   These should be run manually after resolving conflicts"
else
  echo "🔧 Syncing openshift/go.mod with upstream dependencies…"
  pushd openshift > /dev/null
  if go mod tidy; then
    popd > /dev/null
    # Check if there are any changes to commit
    if ! git diff --quiet openshift/go.mod openshift/go.sum; then
      echo "   📝 Changes detected in openshift/go.mod, committing…"
      git add openshift/go.mod openshift/go.sum
      git commit -m "sync openshift/go.mod with upstream dependencies

- go mod tidy

Automated sync after downstream merge to keep openshift/go.mod
in sync with transitive dependencies from go-controller and test/e2e."
      echo "   ✅ openshift/go.mod synced successfully"
      GO_MOD_SYNCED=true
    else
      echo "   ℹ️  No changes needed in openshift/go.mod"
    fi
  else
    popd > /dev/null
    echo "   ⚠️  go mod tidy failed in openshift/"
    GO_MOD_FAILED=true
  fi
fi

if [[ "${GO_MOD_FAILED:-false}" != "true" ]] && [[ "${CONFLICT:-false}" != "true" ]]; then
  echo "🧪 Syncing test annotations with upstream changes…"
  pushd openshift > /dev/null
  if go mod vendor; then
    popd > /dev/null
    if ./openshift/hack/update-tests-annotation.sh; then
      if ! git diff --quiet openshift/test/generated/zz_generated.annotations.go; then
        echo "   📝 Changes detected in test annotations, committing…"
        git add openshift/test/generated/zz_generated.annotations.go
        git commit -m "sync test annotations with upstream changes

- go mod vendor
- ./openshift/hack/update-tests-annotation.sh

Automated sync after downstream merge to keep test annotations
in sync with upstream test modifications and rules.go changes."
        echo "   ✅ Test annotations synced successfully"
        TEST_ANNOTATIONS_SYNCED=true
      else
        echo "   ℹ️  No changes needed in test annotations"
      fi

      # Validate test lists after successful annotation sync
      echo "🔍 Validating test lists…"
      set +e
      VALIDATION_OUTPUT=$(./openshift/hack/validate-test-lists.sh 2>&1)
      VALIDATION_EXIT=$?
      set -e
      if [[ $VALIDATION_EXIT -eq 1 ]]; then
        echo "   ⚠️  Test list validation failed"
        TEST_LIST_MISMATCH=true

        ORPHANED_TESTS=$(echo "$VALIDATION_OUTPUT" | sed -n '/ORPHANED_TESTS_START/,/ORPHANED_TESTS_END/p' | sed '1d;$d') || true
        NEW_TESTS=$(echo "$VALIDATION_OUTPUT" | sed -n '/NEW_TESTS_START/,/NEW_TESTS_END/p' | sed '1d;$d') || true
      elif [[ $VALIDATION_EXIT -ne 0 ]]; then
        printf '%s\n' "$VALIDATION_OUTPUT" >&2
        echo "   ⚠️  Test validation script failed unexpectedly (exit $VALIDATION_EXIT)"
        TEST_VALIDATION_FAILED=true
      fi
    else
      echo "   ⚠️  Test annotation sync failed"
      TEST_ANNOTATIONS_FAILED=true
    fi
  else
    popd > /dev/null
    echo "   ⚠️  Test annotation sync failed"
    TEST_ANNOTATIONS_FAILED=true
  fi
fi

echo "📤 Pushing branch to origin…"
GIT_AUTH_HEADER=$(printf 'x-access-token:%s' "${GITHUB_TOKEN}" | openssl base64 -A)
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=http.extraHeader \
GIT_CONFIG_VALUE_0="Authorization: Basic ${GIT_AUTH_HEADER}" \
  retry_git "push downstream merge branch" "" "${WORKFLOW_DEADLINE_SECONDS}" git push origin "$BRANCH"

echo "✏️  Opening Pull Request…"
PR_TITLE="NO-JIRA: DownStream Merge [$(date +%m-%d-%Y)]"
PR_BODY="Automated merge of upstream/${UPSTREAM_BRANCH} → ${DEFAULT_BRANCH}."
if [[ "${GO_MOD_SYNCED:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**Note:** This PR includes an automated sync of \`openshift/go.mod\` with upstream dependencies (\`go mod tidy\`)."
fi
if [[ "${TEST_ANNOTATIONS_SYNCED:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**Note:** This PR includes an automated sync of test annotations with upstream test changes (\`go mod vendor\` + \`update-tests-annotation.sh\`)."
fi
if [[ "${CONFLICT:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**⚠️  Merge Conflicts Detected**"$'\n\n'"The following files have conflicts:"$'\n\n'"<details><summary>Click to expand conflicted files</summary>"$'\n\n'"<pre>${CONFLICTED_FILES}</pre></details>"
  if [[ -n "${CONFLICT_SNIPPETS:-}" ]]; then
    PR_BODY="${PR_BODY}"$'\n\n'"**Conflict details:**"$'\n\n'"<details><summary>Click to expand conflict markers</summary>"$'\n'"${CONFLICT_SNIPPETS}"$'\n'"</details>"
  fi
  if [[ -n "${UPSTREAM_FILE_CONTEXT:-}" ]]; then
    PR_BODY="${PR_BODY}"$'\n\n'"**Upstream commits that touched conflicted files:**"$'\n\n'"<details><summary>Click to expand</summary>"$'\n'"${UPSTREAM_FILE_CONTEXT}"$'\n'"</details>"
  fi
  PR_BODY="${PR_BODY}"$'\n\n'"[View full upstream diff](${COMPARE_URL})"
  PR_BODY="${PR_BODY}"$'\n\n'"**Automated steps skipped due to conflicts:**"
  PR_BODY="${PR_BODY}"$'\n'"- \`cd openshift && go mod tidy\`"
  PR_BODY="${PR_BODY}"$'\n'"- \`go mod vendor && ./openshift/hack/update-tests-annotation.sh\`"
  PR_BODY="${PR_BODY}"$'\n'"- \`./openshift/hack/validate-test-lists.sh\`"
  PR_BODY="${PR_BODY}"$'\n\n'"**Resolution steps:**"
  PR_BODY="${PR_BODY}"$'\n'"\`\`\`bash"
  PR_BODY="${PR_BODY}"$'\n'"git clone https://github.com/${DOWNSTREAM_REPO} && cd \$(basename ${DOWNSTREAM_REPO})"
  PR_BODY="${PR_BODY}"$'\n'"git checkout ${BRANCH}"
  PR_BODY="${PR_BODY}"$'\n'"# resolve conflicts in the files listed above, then:"
  PR_BODY="${PR_BODY}"$'\n'"git add <resolved-files> && git commit"
  PR_BODY="${PR_BODY}"$'\n'"cd openshift && go mod tidy && cd .."
  PR_BODY="${PR_BODY}"$'\n'"go mod vendor && ./openshift/hack/update-tests-annotation.sh"
  PR_BODY="${PR_BODY}"$'\n'"./openshift/hack/validate-test-lists.sh"
  PR_BODY="${PR_BODY}"$'\n'"git push origin ${BRANCH}"
  PR_BODY="${PR_BODY}"$'\n'"\`\`\`"
fi
if [[ "${TEST_LIST_MISMATCH:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**⚠️  Test List Validation Failed**"
  if [[ -n "${ORPHANED_TESTS:-}" ]]; then
    PR_BODY="${PR_BODY}"$'\n\n'"Orphaned tests (in tests.go but don't exist anymore):"$'\n\n'"<details><summary>Click to expand</summary>"$'\n\n'"<pre>${ORPHANED_TESTS}</pre></details>"
  fi
  if [[ -n "${NEW_TESTS:-}" ]]; then
    PR_BODY="${PR_BODY}"$'\n\n'"New tests (exist but not in tests.go):"$'\n\n'"<details><summary>Click to expand</summary>"$'\n\n'"<pre>${NEW_TESTS}</pre></details>"
  fi
fi
# Make it a draft if we detected conflicts or go mod failures (keeps Prow from auto-running presubmits).
DRAFT=$( [[ "${CONFLICT:-false}" == "true" || "${GO_MOD_FAILED:-false}" == "true" || "${TEST_ANNOTATIONS_FAILED:-false}" == "true" || "${TEST_LIST_MISMATCH:-false}" == "true" || "${TEST_VALIDATION_FAILED:-false}" == "true" ]] && echo true || echo false )
# Build the PR JSON $PAYLOAD
PAYLOAD=$(
  jq -nc \
    --arg title     "$PR_TITLE" \
    --arg head      "$BRANCH" \
    --arg base      "$DEFAULT_BRANCH" \
    --arg body      "$PR_BODY" \
    --argjson draft "$DRAFT" \
    '{title: $title, head: $head, base: $base, body: $body, draft: $draft}'
)

PR_NUM=$(
  github_api_request "create downstream merge pull request" "${WORKFLOW_DEADLINE_SECONDS}" \
    token "${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls" \
  | jq -r .number
)
if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
  echo "❌ ERROR: failed to create PR" >&2
  exit 1
fi
echo "🔖 Opened PR #${PR_NUM}"

if [[ "${CONFLICT:-false}" == "true" || "${GO_MOD_FAILED:-false}" == "true" || "${TEST_ANNOTATIONS_FAILED:-false}" == "true" || "${TEST_LIST_MISMATCH:-false}" == "true" || "${TEST_VALIDATION_FAILED:-false}" == "true" ]]; then
  FAILURES=()

  [[ "${CONFLICT:-false}" == "true" ]] && FAILURES+=("CONFLICT")
  [[ "${GO_MOD_FAILED:-false}" == "true" ]] && FAILURES+=("GO MOD FAILED")
  [[ "${TEST_ANNOTATIONS_FAILED:-false}" == "true" ]] && FAILURES+=("TEST ANNOTATIONS FAILED")
  [[ "${TEST_LIST_MISMATCH:-false}" == "true" ]] && FAILURES+=("TEST LIST MISMATCH")
  [[ "${TEST_VALIDATION_FAILED:-false}" == "true" ]] && FAILURES+=("TEST VALIDATION FAILED")

  TITLE_PREFIX="${FAILURES[0]}"
  for failure in "${FAILURES[@]:1}"; do
    TITLE_PREFIX+=" + ${failure}"
  done

  HOLD_BODY="/hold"$'\n'"**Resolution required — see PR description for full details.**"$'\n'
  HOLD_BODY+=$'\n'"**Steps:**"
  [[ "${CONFLICT:-false}" == "true" ]] && HOLD_BODY+=$'\n'"1. Resolve merge conflicts in: ${CONFLICTED_FILES//$'\n'/, }"
  [[ "${GO_MOD_FAILED:-false}" == "true" ]] && HOLD_BODY+=$'\n'"1. Run: \`cd openshift && go mod tidy\`"
  [[ "${TEST_ANNOTATIONS_FAILED:-false}" == "true" ]] && HOLD_BODY+=$'\n'"1. Run: \`go mod vendor && ./openshift/hack/update-tests-annotation.sh\`"
  [[ "${TEST_LIST_MISMATCH:-false}" == "true" ]] && HOLD_BODY+=$'\n'"1. Update \`openshift/test/tests.go\` with orphaned/new tests"
  [[ "${TEST_VALIDATION_FAILED:-false}" == "true" ]] && HOLD_BODY+=$'\n'"1. Check validation script output for errors"
  HOLD_BODY+=$'\n'"1. Mark PR as ready for review"
  HOLD_BODY+=$'\n'"1. \`/unhold\`"

  echo "🚨 ${TITLE_PREFIX}, holding PR #${PR_NUM}"
  NEW_TITLE="${TITLE_PREFIX}! ${PR_TITLE}"
  TITLE_PAYLOAD=$(jq -nc --arg title "$NEW_TITLE" '{title: $title}')
  github_api_request "mark downstream merge pull request" "${WORKFLOW_DEADLINE_SECONDS}" token "${GITHUB_TOKEN}" -X PATCH -d "$TITLE_PAYLOAD" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls/${PR_NUM}"
  COMMENT_PAYLOAD=$(jq -nc --arg body "$HOLD_BODY" '{body: $body}')
  github_api_request "hold downstream merge pull request" "${WORKFLOW_DEADLINE_SECONDS}" token "${GITHUB_TOKEN}" -X POST -d "$COMMENT_PAYLOAD" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"
  echo "⚠️  PR #${PR_NUM} held for manual resolution"
  exit 1
else
  echo "💬 Posting payload commands and pipeline required…"
  COMMENT_BODY="/payload ${RELEASE} ci blocking
/payload ${RELEASE} nightly blocking
/pipeline required"
  COMMENT_PAYLOAD=$(jq -nc --arg body "$COMMENT_BODY" '{body: $body}')
  github_api_request "trigger downstream merge pull request tests" "${WORKFLOW_DEADLINE_SECONDS}" token "${GITHUB_TOKEN}" -X POST \
       -d "$COMMENT_PAYLOAD" \
       "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"
fi

# Credentials are no longer needed. Clear them before restoring inherited
# tracing so no later command can accidentally expand them into the log.
JWT=
GITHUB_TOKEN=
GIT_AUTH_HEADER=
if [[ "${WAS_TRACING}" == "true" ]]; then
  set -x
fi
echo "✅ Merge succeeded; PR #${PR_NUM} created."
