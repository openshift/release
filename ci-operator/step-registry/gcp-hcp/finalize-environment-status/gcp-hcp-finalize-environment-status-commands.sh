#!/usr/bin/env bash
set -euo pipefail

readonly token_path="${GITHUB_TOKEN_PATH:-/etc/github-private/oauth}"
readonly targets_path="${SHARED_DIR}/gcp-hcp-environment-status-targets.json"
readonly skip_path="${SHARED_DIR}/gcp-hcp-environment-status-skipped"
readonly tests_started_path="${SHARED_DIR}/gcp-hcp-e2e-tests-started"
readonly tests_passed_path="${SHARED_DIR}/gcp-hcp-e2e-tests-passed"
readonly api="https://api.github.com/repos/openshift-online/gcp-hcp-infra"

if [[ -e "${skip_path}" ]]; then
  echo "Status publication was skipped; nothing to finalize"
  exit 0
fi
if [[ ! -s "${targets_path}" ]] || ! jq -e '
  (.context | type) == "string" and
  (.target_url // "" | startswith("https://prow.ci.openshift.org/view/gs/test-platform-results-public/")) and
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
  response="$(github_get "${api}/branches/${encoded_branch}")" || return
  jq -er '.commit.sha | select(test("^[0-9a-f]{40}$"))' <<<"${response}"
}

state=failure
description="HostedCluster lifecycle did not pass"
if [[ ! -e "${tests_started_path}" ]]; then
  description="HostedCluster lifecycle did not run"
fi
if [[ -e "${tests_passed_path}" ]]; then
  state=success
  description="HostedCluster lifecycle passed on deployed revision"
  # A successful test only counts for the exact revisions captured before it
  # started, while their Terraform and ArgoCD deployment checks remain green.
  while IFS= read -r target; do
    branch="$(jq -r '.branch' <<<"${target}")"
    sha="$(jq -r '.sha' <<<"${target}")"
    contexts="$(jq -c '.contexts' <<<"${target}")"
    check_runs="$(jq -c '.check_runs' <<<"${target}")"
    if ! current_sha="$(branch_sha "${branch}")"; then
      echo "Could not verify deployment branch ${branch} after the lifecycle test" >&2
      description="Could not verify promotion branch after lifecycle"
      state=failure
      break
    fi
    if [[ "${current_sha}" != "${sha}" ]]; then
      echo "Deployment branch ${branch} changed during the lifecycle test" >&2
      description="Promotion branch changed during lifecycle"
      state=failure
      break
    fi
    missing=""
    if [[ "${contexts}" != "[]" ]]; then
      if ! status_response="$(github_get "${api}/commits/${sha}/status?per_page=100")"; then
        echo "Could not verify deployment statuses on ${branch}@${sha}" >&2
        description="Could not verify deployment checks after lifecycle"
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
      missing_checks=""
      while IFS= read -r check_name; do
        encoded_check_name="$(jq -nr --arg name "${check_name}" '$name | @uri')"
        if ! checks_response="$(github_get "${api}/commits/${sha}/check-runs?check_name=${encoded_check_name}&per_page=100")"; then
          echo "Could not verify ${check_name} on ${branch}@${sha}" >&2
          description="Could not verify deployment checks after lifecycle"
          state=failure
          break
        fi
        conclusion="$(jq -r --arg wanted "${check_name}" '
          ([(.check_runs // [])[] | select(.name == $wanted)] | sort_by(.id) | last | .conclusion) // ""
        ' <<<"${checks_response}")"
        if [[ "${conclusion}" != "success" ]]; then
          missing_checks="${missing_checks}${missing_checks:+$'\n'}${check_name}"
        fi
      done < <(jq -r '.[]' <<<"${check_runs}")
      if [[ "${state}" == "failure" ]]; then
        break
      fi
      if [[ -n "${missing_checks}" ]]; then
        missing="${missing}${missing:+$'\n'}${missing_checks}"
      fi
    fi
    if [[ -n "${missing}" ]]; then
      echo "Deployment checks changed during the lifecycle test on ${branch}@${sha}:" >&2
      echo "${missing}" >&2
      description="Deployment checks changed during lifecycle"
      state=failure
      break
    fi
  done < <(jq -c '.targets[]' "${targets_path}")
fi

target_url="$(jq -r '.target_url' "${targets_path}")"
readonly target_url
context="$(jq -r '.context' "${targets_path}")"
payload="$(jq -cn --arg state "${state}" --arg context "${context}" \
  --arg description "${description}" --arg target_url "${target_url}" '{
  state: $state, context: $context, description: $description,
  target_url: $target_url
}')"

post_error=0
# If the lifecycle passed but promotion validation failed, the Prow job must
# fail as well as publishing a failed status on the captured commit.
if [[ -e "${tests_passed_path}" && "${state}" != "success" ]]; then
  post_error=1
fi
while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  sha="$(jq -r '.sha' <<<"${target}")"
  echo "Posting ${state} ${context} to ${branch}@${sha}"
  if ! post_response="$(curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-all-errors --retry-delay 2 --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $(<"${token_path}")" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --data "${payload}" "${api}/statuses/${sha}")"; then
    post_message="$(jq -r '.message // empty' <<<"${post_response}" 2>/dev/null || true)"
    echo "ERROR: Could not post ${state} ${context} to ${branch}@${sha}: ${post_message:-no GitHub error message}" >&2
    post_error=1
  fi
done < <(jq -c '.targets[]' "${targets_path}")
exit "${post_error}"
