#!/usr/bin/env bash
set -euo pipefail

readonly token_path="${GITHUB_TOKEN_PATH:-/etc/github-private/oauth}"
readonly targets_path="${SHARED_DIR}/gcp-hcp-environment-status-targets.json"
readonly skip_path="${SHARED_DIR}/gcp-hcp-environment-status-skipped"
readonly api="https://api.github.com/repos/openshift-online/gcp-hcp-infra"

if [[ -z "${JOB_SPEC:-}" ]]; then
  echo "ERROR: JOB_SPEC is required to identify the Prow job type" >&2
  exit 1
fi

# A postsubmit is tied to the pushed promotion commit. Use that event SHA,
# even if a newer promotion lands before the job starts. The branch drift
# check below then fails the old run instead of testing a different commit.
job_type="$(jq -r '.type // empty' <<<"${JOB_SPEC}")"
if [[ "${job_type}" == "postsubmit" ]]; then
  if ! jq -e '
    .refs.org == "openshift-online" and
    .refs.repo == "gcp-hcp-infra" and
    (.refs.base_ref | type) == "string" and
    (.refs.base_sha | type) == "string" and
    (.refs.base_sha | test("^[0-9a-f]{40}$")) and
    ((.refs.pulls // []) | length) == 0
  ' <<<"${JOB_SPEC}" >/dev/null; then
    echo "ERROR: postsubmit JOB_SPEC must identify an openshift-online/gcp-hcp-infra promotion commit" >&2
    exit 1
  fi
fi

# An ordinary presubmit tests its own source checkout against an already
# deployed environment. A pj-rehearse run of an HC periodic job also tests
# that environment, and must exercise the status publication path.
if [[ "${job_type}" != "postsubmit" ]] && ! jq -e --arg periodic_job_prefix "periodic-ci-openshift-online-gcp-hcp-infra-main-e2e-hostedcluster-" '
  . as $job |
  $job.type == "periodic" or
  ($job.type == "presubmit" and
   $job.refs.org == "openshift" and
   $job.refs.repo == "release" and
   ($job.refs.pulls | length) == 1 and
   ($job.job | test("^rehearse-" + ($job.refs.pulls[0].number | tostring) + "-" + $periodic_job_prefix + "(int|stg)$")))
' <<<"${JOB_SPEC}" >/dev/null; then
  touch "${skip_path}"
  echo "Skipping deployed-commit status for an ordinary presubmit"
  exit 0
fi

if [[ ! "${JOB_NAME:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ ! "${BUILD_ID:-}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: JOB_NAME or BUILD_ID is missing or invalid" >&2
  exit 1
fi
if [[ ! -s "${token_path}" ]]; then
  echo "ERROR: GitHub credential is missing or empty" >&2
  exit 1
fi
if [[ ! "${E2E_STATUS_CONTEXT:-}" =~ ^[A-Za-z0-9][A-Za-z0-9/_-]{0,99}$ ]]; then
  echo "ERROR: E2E_STATUS_CONTEXT is missing or invalid" >&2
  exit 1
fi
readonly status_wait_seconds="${E2E_STATUS_WAIT_SECONDS:-1800}"
readonly status_poll_seconds="${E2E_STATUS_POLL_SECONDS:-60}"
if [[ ! "${status_wait_seconds}" =~ ^[1-9][0-9]{0,3}$ ]] || (( status_wait_seconds > 1800 )); then
  echo "ERROR: E2E_STATUS_WAIT_SECONDS must be between 1 and 1800" >&2
  exit 1
fi
if [[ ! "${status_poll_seconds}" =~ ^[1-9][0-9]{0,3}$ ]] || (( status_poll_seconds > status_wait_seconds )); then
  echo "ERROR: E2E_STATUS_POLL_SECONDS must be between 1 and E2E_STATUS_WAIT_SECONDS" >&2
  exit 1
fi
if ! jq -e '
  type == "array" and length > 0 and
  ((map(.branch) | unique | length) == length) and
  all(.[];
    . as $target |
    ($target.contexts // []) as $contexts |
    ($target.check_runs // []) as $check_runs |
    ($target.branch | type) == "string" and
    ($target.branch | test("^environment/(global|sector)-[a-z0-9-]+$")) and
    ($contexts | type) == "array" and
    all($contexts[]; type == "string" and length > 0) and
    ($check_runs | type) == "array" and
    all($check_runs[]; type == "string" and length > 0) and
    (($contexts | length) + ($check_runs | length) > 0)
  )
' <<<"${E2E_STATUS_TARGETS:-}" >/dev/null; then
  echo "ERROR: E2E_STATUS_TARGETS must list unique promotion branches and deployment statuses or check runs" >&2
  exit 1
fi
if [[ "${job_type}" == "postsubmit" ]] && ! jq -e --argjson targets "${E2E_STATUS_TARGETS}" '
  ($targets | length) == 1 and
  .refs.base_ref == $targets[0].branch
' <<<"${JOB_SPEC}" >/dev/null; then
  echo "ERROR: postsubmit target must be its triggering promotion branch" >&2
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

# Spyglass stores PR rehearsal logs separately from periodic and postsubmit logs.
readonly spyglass_base="https://prow.ci.openshift.org/view/gs/test-platform-results-public"
if [[ "${job_type}" == "presubmit" ]]; then
  pull_number="$(jq -r '.refs.pulls[0].number // empty' <<<"${JOB_SPEC}")"
  if [[ ! "${pull_number}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: rehearsal pull request number is missing or invalid" >&2
    exit 1
  fi
  target_url="${spyglass_base}/pr-logs/pull/openshift_release/${pull_number}/${JOB_NAME}/${BUILD_ID}"
else
  target_url="${spyglass_base}/logs/${JOB_NAME}/${BUILD_ID}"
fi
readonly target_url
resolved='[]'
while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  contexts="$(jq -c '.contexts // []' <<<"${target}")"
  check_runs="$(jq -c '.check_runs // []' <<<"${target}")"
  if [[ "${job_type}" == "postsubmit" ]]; then
    sha="$(jq -r '.refs.base_sha' <<<"${JOB_SPEC}")"
  else
    sha="$(branch_sha "${branch}")"
  fi
  resolved="$(jq -cn --argjson targets "${resolved}" --arg branch "${branch}" \
    --arg sha "${sha}" --argjson contexts "${contexts}" --argjson check_runs "${check_runs}" \
    '$targets + [{branch: $branch, sha: $sha, contexts: $contexts, check_runs: $check_runs}]')"
done < <(jq -c '.[]' <<<"${E2E_STATUS_TARGETS}")

# Record every target before posting. If any status POST or deployment check
# fails, the post step can still publish failure to all captured commits.
jq -cn --arg context "${E2E_STATUS_CONTEXT}" --arg target_url "${target_url}" \
  --argjson targets "${resolved}" \
  '{context: $context, target_url: $target_url, targets: $targets}' >"${targets_path}"

while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  sha="$(jq -r '.sha' <<<"${target}")"
  payload="$(jq -cn --arg context "${E2E_STATUS_CONTEXT}" --arg target_url "${target_url}" '{
    state: "pending", context: $context,
    description: "HostedCluster lifecycle is running", target_url: $target_url
  }')"
  echo "Posting pending ${E2E_STATUS_CONTEXT} to ${branch}@${sha}"
  curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-all-errors --retry-delay 2 --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $(<"${token_path}")" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --data "${payload}" "${api}/statuses/${sha}" >/dev/null
done < <(jq -c '.targets[]' "${targets_path}")

# Wait for deployment of the captured revision before starting the lifecycle
# test. Keep checking the branch so a newer promotion cannot pass this run.
readonly deadline=$((SECONDS + status_wait_seconds))
while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  sha="$(jq -r '.sha' <<<"${target}")"
  contexts="$(jq -c '.contexts' <<<"${target}")"
  check_runs="$(jq -c '.check_runs' <<<"${target}")"
  while true; do
    if [[ "$(branch_sha "${branch}")" != "${sha}" ]]; then
      echo "ERROR: ${branch} advanced before the lifecycle test started" >&2
      exit 1
    fi
    missing=""
    if [[ "${contexts}" != "[]" ]]; then
      status_response="$(github_get "${api}/commits/${sha}/status?per_page=100")"
      missing="$(jq -r --argjson contexts "${contexts}" '
        (.statuses // []) as $statuses |
        $contexts[] as $wanted |
        ([$statuses[] | select(.context == $wanted)] | sort_by(.id) | last | .state) as $state |
        select($state != "success") | $wanted
      ' <<<"${status_response}")"
    fi
    if [[ "${check_runs}" != "[]" ]]; then
      missing_checks=""
      while IFS= read -r check_name; do
        encoded_check_name="$(jq -nr --arg name "${check_name}" '$name | @uri')"
        checks_response="$(github_get "${api}/commits/${sha}/check-runs?check_name=${encoded_check_name}&per_page=100")"
        conclusion="$(jq -r --arg wanted "${check_name}" '
          ([(.check_runs // [])[] | select(.name == $wanted)] | sort_by(.id) | last | .conclusion) // ""
        ' <<<"${checks_response}")"
        if [[ "${conclusion}" != "success" ]]; then
          missing_checks="${missing_checks}${missing_checks:+$'\n'}${check_name}"
        fi
      done < <(jq -r '.[]' <<<"${check_runs}")
      if [[ -n "${missing_checks}" ]]; then
        missing="${missing}${missing:+$'\n'}${missing_checks}"
      fi
    fi
    if [[ -z "${missing}" ]]; then
      if [[ "$(branch_sha "${branch}")" != "${sha}" ]]; then
        echo "ERROR: ${branch} advanced before the lifecycle test started" >&2
        exit 1
      fi
      echo "Deployment checks passed on ${branch}@${sha}"
      break
    fi
    if (( SECONDS >= deadline )); then
      echo "ERROR: timed out waiting for deployment checks on ${branch}@${sha}:" >&2
      echo "${missing}" >&2
      exit 1
    fi
    remaining=$((deadline - SECONDS))
    pause=$((remaining < status_poll_seconds ? remaining : status_poll_seconds))
    echo "Waiting ${pause}s for deployment checks on ${branch}@${sha}:"
    echo "${missing}"
    sleep "${pause}"
  done
done < <(jq -c '.targets[]' "${targets_path}")

echo "Captured deployed promotion commits and verified their deployment checks"
