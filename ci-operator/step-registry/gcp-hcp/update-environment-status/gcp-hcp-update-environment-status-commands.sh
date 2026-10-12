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

# A presubmit tests its own source checkout against an already deployed INT
# environment. It must not overwrite the periodic result on deployed commits.
if [[ "$(jq -r '.type // empty' <<<"${JOB_SPEC}")" != "periodic" ]]; then
  touch "${skip_path}"
  echo "Skipping deployed-commit status for a non-periodic job"
  exit 0
fi

if [[ ! "${PROW_JOB_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "ERROR: PROW_JOB_ID is missing or invalid" >&2
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
if ! jq -e '
  type == "array" and length > 0 and
  ((map(.branch) | unique | length) == length) and
  all(.[];
    (.branch | type) == "string" and
    (.branch | test("^environment/(global|sector)-[a-z0-9-]+$")) and
    (.contexts | type) == "array" and
    (.contexts | length) > 0 and
    all(.contexts[]; type == "string" and length > 0)
  )
' <<<"${E2E_STATUS_TARGETS:-}" >/dev/null; then
  echo "ERROR: E2E_STATUS_TARGETS must list unique promotion branches and deployment contexts" >&2
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

readonly target_url="https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID}"
resolved='[]'
while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  contexts="$(jq -c '.contexts' <<<"${target}")"
  sha="$(branch_sha "${branch}")"
  resolved="$(jq -cn --argjson targets "${resolved}" --arg branch "${branch}" \
    --arg sha "${sha}" --argjson contexts "${contexts}" \
    '$targets + [{branch: $branch, sha: $sha, contexts: $contexts}]')"
done < <(jq -c '.[]' <<<"${E2E_STATUS_TARGETS}")

# Record every target before posting. If any status POST or deployment check
# fails, the post step can still publish failure to all captured commits.
jq -cn --arg context "${E2E_STATUS_CONTEXT}" --argjson targets "${resolved}" \
  '{context: $context, targets: $targets}' >"${targets_path}"

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

# These checks prove the captured branch revisions were deployed before the
# lifecycle test started. The promoter also gates on the same checks.
while IFS= read -r target; do
  branch="$(jq -r '.branch' <<<"${target}")"
  sha="$(jq -r '.sha' <<<"${target}")"
  contexts="$(jq -c '.contexts' <<<"${target}")"
  status_response="$(github_get "${api}/commits/${sha}/status?per_page=100")"
  missing="$(jq -r --argjson contexts "${contexts}" '
    (.statuses // []) as $statuses |
    $contexts[] as $wanted |
    ([$statuses[] | select(.context == $wanted)] | sort_by(.id) | last | .state) as $state |
    select($state != "success") | $wanted
  ' <<<"${status_response}")"
  if [[ -n "${missing}" ]]; then
    echo "ERROR: deployment checks are not successful on ${branch}@${sha}:" >&2
    echo "${missing}" >&2
    exit 1
  fi
  if [[ "$(branch_sha "${branch}")" != "${sha}" ]]; then
    echo "ERROR: ${branch} advanced before the lifecycle test started" >&2
    exit 1
  fi
done < <(jq -c '.targets[]' "${targets_path}")

echo "Captured deployed promotion commits and verified their deployment checks"
