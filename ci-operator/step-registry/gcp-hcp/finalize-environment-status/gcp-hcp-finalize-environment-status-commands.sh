#!/usr/bin/env bash
set -euo pipefail

readonly token_path="${GITHUB_TOKEN_PATH:-/etc/github-private/oauth}"
readonly targets_path="${SHARED_DIR}/gcp-hcp-environment-status-targets.json"
readonly skip_path="${SHARED_DIR}/gcp-hcp-environment-status-skipped"
readonly tests_passed_path="${SHARED_DIR}/gcp-hcp-e2e-tests-passed"
readonly api="https://api.github.com/repos/openshift-online/gcp-hcp-infra"

if [[ -e "${skip_path}" ]]; then
  echo "No deployed-commit status to finalize for this non-periodic job"
  exit 0
fi
if [[ ! -s "${targets_path}" ]] || ! jq -e '
  (.context | type) == "string" and
  (.targets | type) == "array" and
  (.targets | length) > 0 and
  all(.targets[]; (.branch | type) == "string" and
    (.sha | test("^[0-9a-f]{40}$")) and
    (.contexts | type) == "array" and
    (.check_runs | type) == "array" and
    ((.contexts | length) + (.check_runs | length) > 0))
' "${targets_path}" >/dev/null; then
  echo "ERROR: captured environment status targets are missing or invalid" >&2
  exit 1
fi
if [[ ! "${PROW_JOB_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "ERROR: PROW_JOB_ID is missing or invalid" >&2
  exit 1
fi
if [[ ! -s "${token_path}" ]]; then
  echo "ERROR: GitHub credential is missing or empty" >&2
  exit 1
fi

github_get() {
  curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-all-errors --retry-delay 2 \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $(<"${token_path}")" \
    --header "X-GitHub-Api-Version: 2022-11-28" "$1"
}

branch_sha() {
  local encoded_branch response
  encoded_branch="$(jq -nr --arg branch "$1" '$branch | @uri')"
  response="$(github_get "${api}/branches/${encoded_branch}")"
  jq -er '.commit.sha | select(test("^[0-9a-f]{40}$"))' <<<"${response}"
}

state=failure
if [[ -e "${tests_passed_path}" ]]; then
  state=success
  # A successful test only counts for the exact revisions captured before it
  # started, while their Terraform and ArgoCD deployment checks remain green.
  while IFS= read -r target; do
    branch="$(jq -r '.branch' <<<"${target}")"
    sha="$(jq -r '.sha' <<<"${target}")"
    contexts="$(jq -c '.contexts' <<<"${target}")"
    check_runs="$(jq -c '.check_runs' <<<"${target}")"
    if ! current_sha="$(branch_sha "${branch}")" || [[ "${current_sha}" != "${sha}" ]]; then
      echo "Deployment branch ${branch} changed during the lifecycle test" >&2
      state=failure
      break
    fi
    missing=""
    if [[ "${contexts}" != "[]" ]]; then
      if ! status_response="$(github_get "${api}/commits/${sha}/status?per_page=100")"; then
        echo "Could not verify deployment statuses on ${branch}@${sha}" >&2
        state=failure
        break
      fi
      missing="$(jq -r --argjson contexts "${contexts}" '
        (.statuses // []) as $statuses |
        $contexts[] as $wanted |
        ([$statuses[] | select(.context == $wanted)] | sort_by(.id) | last | .state) as $status_state |
        select($status_state != "success") | $wanted
      ' <<<"${status_response}")"
    fi
    if [[ "${check_runs}" != "[]" ]]; then
      if ! checks_response="$(github_get "${api}/commits/${sha}/check-runs?per_page=100")"; then
        echo "Could not verify deployment check runs on ${branch}@${sha}" >&2
        state=failure
        break
      fi
      missing_checks="$(jq -r --argjson checks "${check_runs}" '
        (.check_runs // []) as $runs |
        $checks[] as $wanted |
        ([$runs[] | select(.name == $wanted)] | sort_by(.id) | last | .conclusion) as $conclusion |
        select($conclusion != "success") | $wanted
      ' <<<"${checks_response}")"
      if [[ -n "${missing_checks}" ]]; then
        missing="${missing}${missing:+$'\n'}${missing_checks}"
      fi
    fi
    if [[ -n "${missing}" ]]; then
      echo "Deployment checks changed during the lifecycle test on ${branch}@${sha}:" >&2
      echo "${missing}" >&2
      state=failure
      break
    fi
  done < <(jq -c '.targets[]' "${targets_path}")
fi

if [[ "${state}" == "success" ]]; then
  description="HostedCluster lifecycle passed on deployed revision"
else
  description="HostedCluster lifecycle failed or deployment changed"
fi
readonly target_url="https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID}"
context="$(jq -r '.context' "${targets_path}")"
payload="$(jq -cn --arg state "${state}" --arg context "${context}" \
  --arg description "${description}" --arg target_url "${target_url}" '{
  state: $state, context: $context, description: $description,
  target_url: $target_url
}')"

post_error=0
while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  sha="$(jq -r '.sha' <<<"${target}")"
  echo "Posting ${state} ${context} to ${branch}@${sha}"
  if ! curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-all-errors --retry-delay 2 --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $(<"${token_path}")" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --data "${payload}" "${api}/statuses/${sha}" >/dev/null; then
    post_error=1
  fi
done < <(jq -c '.targets[]' "${targets_path}")
exit "${post_error}"
