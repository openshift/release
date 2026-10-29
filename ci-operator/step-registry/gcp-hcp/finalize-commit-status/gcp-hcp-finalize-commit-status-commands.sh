#!/usr/bin/env bash

set -euo pipefail

readonly status_context="${E2E_STATUS_CONTEXT:-e2e/platform}"
readonly target_org="openshift-online"
readonly target_repo="gcp-hcp-infra"
readonly token_path="${GITHUB_TOKEN_PATH:-/etc/github-private/oauth}"
readonly tested_sha_path="${SHARED_DIR}/gcp-hcp-tested-sha"
readonly tests_passed_path="${SHARED_DIR}/gcp-hcp-e2e-tests-passed"

if [[ ! -s "${tested_sha_path}" ]]; then
  echo "ERROR: tested commit SHA is missing or empty" >&2
  exit 1
fi
tested_sha="$(<"${tested_sha_path}")"

if [[ ! "${tested_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: tested commit SHA is not a full lowercase Git SHA" >&2
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

if [[ -e "${tests_passed_path}" ]]; then
  state="success"
  description="GCP HCP platform E2E test passed"
else
  state="failure"
  description="GCP HCP platform E2E test failed"
fi

readonly target_url="https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID}"
payload="$(jq -cn \
  --arg state "${state}" \
  --arg description "${description}" \
  --arg target_url "${target_url}" \
  --arg context "${status_context}" '{
  state: $state,
  context: $context,
  description: $description,
  target_url: $target_url
}')"

echo "Posting ${state} ${status_context} status to ${target_org}/${target_repo}@${tested_sha}"
curl \
  --fail-with-body \
  --silent \
  --show-error \
  --connect-timeout 10 \
  --max-time 30 \
  --retry 3 \
  --retry-all-errors \
  --retry-delay 2 \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer $(<"${token_path}")" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "${payload}" \
  "https://api.github.com/repos/${target_org}/${target_repo}/statuses/${tested_sha}" \
  >/dev/null
echo "GitHub accepted the ${state} ${status_context} status"
